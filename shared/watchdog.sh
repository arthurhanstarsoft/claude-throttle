#!/usr/bin/env bash
# watchdog.sh — Layer 2 safety net (hook-independent).
#
# Continuously watches system memory pressure. When free memory drops below the
# critical threshold (sustained), it SIGSTOPs the heaviest Claude *descendant*
# processes — pausing is reversible, relieves CPU instantly and lets the OS
# reclaim/compress the paused pages. When memory recovers past the (higher)
# resume threshold, it SIGCONTs them. This guarantees the machine never hard
# freezes even when Layer 1 misses a path (e.g. subagent Bash calls).
# Memory reads, the singleton lock, the exclusion list and file-reversal are
# provided by the platform module (macos/ or linux/).

set +e
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_here/common.sh"

ME="$(id -u)"

# ---- singleton guard --------------------------------------------------------
if ! ct_singleton_acquire "$CT_WATCHDOG_PID"; then
  ct_wlog "another watchdog is already running; exiting"
  exit 0
fi

# ---- resume everything we ever paused, on any exit --------------------------
cont_all_paused() {
  [ -f "$CT_PAUSED_LIST" ] || return 0
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && kill -CONT "$p" 2>/dev/null
  done <"$CT_PAUSED_LIST"
}
cleanup() {
  cont_all_paused
  : >"$CT_PAUSED_LIST" 2>/dev/null
  rm -f "$CT_WATCHDOG_PID" 2>/dev/null
}
trap 'cleanup; exit 0' EXIT INT TERM

# Resume any leftovers from a previous (crashed) run before starting fresh.
cont_all_paused
: >"$CT_PAUSED_LIST" 2>/dev/null

ct_wlog "watchdog started os=$CT_OS (crit_free=${CT_CRIT_FREE_PCT}% resume_free=${CT_RESUME_FREE_PCT}% interval=${CT_WATCHDOG_INTERVAL}s)"

# ct_excluded_comm (which processes never to pause) is provided by the platform module.

# Echo "rss pid comm" lines for pausable claude descendants, heaviest first.
ct_pausable_targets() {
  local pids list
  pids="$(ct_claude_descendants | tr '\n' ',' | sed 's/,$//')"
  [ -z "$pids" ] && return 0
  list="$(LC_ALL=C ps -o pid=,uid=,rss=,comm= -p "$pids" 2>/dev/null)"
  [ -z "$list" ] && return 0
  local floor_kb=$(( ${CT_MIN_PAUSE_RSS_MB:-150} * 1024 ))
  printf '%s\n' "$list" | while IFS= read -r line; do
    set -- $line
    local pid="$1" uid="$2" rss="$3"; shift 3
    local comm="$*"
    [ -z "$pid" ] && continue
    [ "$uid" = "$ME" ] || continue           # only our own processes
    [ "$rss" -ge "$floor_kb" ] 2>/dev/null || continue
    ct_excluded_comm "$comm" && continue
    printf '%s %s %s\n' "$rss" "$pid" "$comm"
  done | LC_ALL=C sort -rn -k1,1
}

state=NORMAL
sustained=0

while :; do
  free="$(ct_free_pct)"

  # Reconcile: drop dead PIDs from paused.list; if claude is entirely gone,
  # resume everything and reset.
  if [ -s "$CT_PAUSED_LIST" ]; then
    if [ -z "$(ct_claude_anchors)" ]; then
      cont_all_paused; : >"$CT_PAUSED_LIST"; state=NORMAL; sustained=0
      ct_wlog "claude gone; resumed all and reset"
    else
      tmp="$CT_PAUSED_LIST.tmp"; : >"$tmp"
      while IFS= read -r p; do
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p" >>"$tmp"
      done <"$CT_PAUSED_LIST"
      mv "$tmp" "$CT_PAUSED_LIST" 2>/dev/null
    fi
  fi

  if [ -z "$free" ]; then
    sleep "${CT_WATCHDOG_INTERVAL:-2}"; continue      # can't read pressure; wait
  fi

  if [ "$state" = "NORMAL" ]; then
    if [ "$free" -le "${CT_CRIT_FREE_PCT:-10}" ]; then
      sustained=$((sustained + 1))
      if [ "$sustained" -ge "${CT_CRIT_SUSTAIN:-2}" ]; then
        # Critical: pause the heaviest pausable descendants.
        paused_any=0 count=0
        while IFS= read -r row; do
          [ -z "$row" ] && continue
          set -- $row
          rss="$1"; pid="$2"; shift 2; comm="$*"
          [ "$count" -ge "${CT_PAUSE_COUNT:-2}" ] && break
          if kill -STOP "$pid" 2>/dev/null; then
            echo "$pid" >>"$CT_PAUSED_LIST"
            ct_wlog "PAUSED pid=$pid rss_kb=$rss comm=$comm (free=${free}%)"
            paused_any=1; count=$((count + 1))
          fi
        done <<EOF
$(ct_pausable_targets)
EOF
        if [ "$paused_any" = "1" ]; then
          state=THROTTLED
        else
          ct_wlog "CRITICAL free=${free}% but no pausable target found"
        fi
        sustained=0
      fi
    else
      sustained=0
    fi
  else # THROTTLED
    if [ "$free" -ge "${CT_RESUME_FREE_PCT:-25}" ]; then
      # Resume in reverse order (last paused first).
      if [ -s "$CT_PAUSED_LIST" ]; then
        tac_list="$(ct_reverse "$CT_PAUSED_LIST")"
        while IFS= read -r p; do
          [ -n "$p" ] && { kill -CONT "$p" 2>/dev/null; ct_wlog "RESUMED pid=$p (free=${free}%)"; }
        done <<EOF
$tac_list
EOF
      fi
      : >"$CT_PAUSED_LIST"
      state=NORMAL; sustained=0
    fi
  fi

  sleep "${CT_WATCHDOG_INTERVAL:-2}"
done
