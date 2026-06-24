#!/usr/bin/env bash
# common.sh — shared helpers for claude-throttle.
# Sourced by every other script. No side effects beyond defining vars/functions
# and ensuring the runtime dirs exist.
#
# Portability rule: derive every path from $HOME and this file's own location.
# Never hardcode a username. All numeric parsing forces LC_ALL=C and uses
# integers only (the host locale may use comma decimals).

# ---- resolve our own install root -------------------------------------------
# common.sh lives in <root>/libexec/, so <root> is one dir up.
_ct_self="${BASH_SOURCE[0]}"
# Resolve symlinks to find the real file location.
while [ -L "$_ct_self" ]; do
  _ct_link="$(readlink "$_ct_self")"
  case "$_ct_link" in
    /*) _ct_self="$_ct_link" ;;
    *)  _ct_self="$(cd "$(dirname "$_ct_self")" && pwd)/$_ct_link" ;;
  esac
done
CT_LIBEXEC="$(cd "$(dirname "$_ct_self")" && pwd)"
CT_ROOT="$(cd "$CT_LIBEXEC/.." && pwd)"
unset _ct_self _ct_link

# ---- canonical paths --------------------------------------------------------
CT_CONFIG_DIR="${CT_CONFIG_DIR:-$HOME/.config/claude-throttle}"
CT_CONFIG_FILE="${CT_CONFIG_FILE:-$CT_CONFIG_DIR/config.sh}"
CT_STATE_DIR="${CT_STATE_DIR:-$HOME/.local/state/claude-throttle}"
CT_SLOTS_DIR="$CT_STATE_DIR/slots"
CT_THROTTLE_LOG="$CT_STATE_DIR/throttle.log"
CT_WATCHDOG_LOG="$CT_STATE_DIR/watchdog.log"
CT_WATCHDOG_PID="$CT_STATE_DIR/watchdog.pid"
CT_PAUSED_LIST="$CT_STATE_DIR/paused.list"

CT_BIN="$HOME/.local/bin/claude-throttle"
CT_SETTINGS="$HOME/.claude/settings.json"
CT_PLIST_LABEL="com.user.claude-throttle.watchdog"
CT_PLIST="$HOME/Library/LaunchAgents/$CT_PLIST_LABEL.plist"
CT_PLIST_TEMPLATE="$CT_ROOT/share/$CT_PLIST_LABEL.plist.template"
CT_CONFIG_EXAMPLE="$CT_ROOT/share/config.example.sh"

# ---- defaults ---------------------------------------------------------------
# `:=` means: keep any value already set in the environment, else use the
# default. The config file is sourced AFTER this and can override anything with
# a direct assignment. Precedence: config file > environment > built-in default.
: "${CT_ENABLED:=1}"
: "${CT_GATE_MODE:=heavy}"
: "${CT_HEAVY_REGEX:=(pnpm|npm|yarn|bun|tsc|webpack|vite|jest|vitest|build|test|install|cargo|make|gradle|xcodebuild|docker)}"
: "${CT_MAX_CONCURRENCY:=2}"
: "${CT_ACQUIRE_TIMEOUT:=300}"
: "${CT_POLL:=0.3}"
: "${CT_NICE:=10}"
: "${CT_USE_CPULIMIT:=0}"
: "${CT_CPULIMIT_PCT:=300}"
: "${CT_PRESTART_WAIT:=1}"
: "${CT_PRESTART_TIMEOUT:=60}"
: "${CT_WATCHDOG_INTERVAL:=2}"
: "${CT_CRIT_FREE_PCT:=10}"
: "${CT_RESUME_FREE_PCT:=25}"
: "${CT_CRIT_LOAD:=300}"
: "${CT_CRIT_SUSTAIN:=2}"
: "${CT_PAUSE_COUNT:=2}"
: "${CT_MIN_PAUSE_RSS_MB:=150}"

# ---- load user config (sourced bash; trusted, user-owned) -------------------
if [ -f "$CT_CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CT_CONFIG_FILE"
fi

ct_ensure_dirs() {
  mkdir -p "$CT_STATE_DIR" "$CT_SLOTS_DIR" "$CT_CONFIG_DIR" 2>/dev/null || true
}
ct_ensure_dirs

# ---- logging ----------------------------------------------------------------
# ct_log <logfile> <message...>  — timestamped, append, best-effort.
ct_log() {
  local logfile="$1"; shift
  printf '%s [%d] %s\n' "$(LC_ALL=C date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" \
    >>"$logfile" 2>/dev/null || true
}
ct_tlog() { ct_log "$CT_THROTTLE_LOG" "$@"; }
ct_wlog() { ct_log "$CT_WATCHDOG_LOG" "$@"; }

# ---- metric parsers (LC_ALL=C, integers only) -------------------------------
# Free system memory as an integer percentage (0-100). Echoes "" on failure.
ct_free_pct() {
  local line pct
  line="$(LC_ALL=C memory_pressure 2>/dev/null \
          | grep -i 'free percentage')" || return 0
  # e.g. "System-wide memory free percentage: 39%"
  pct="$(printf '%s' "$line" | LC_ALL=C grep -oE '[0-9]+' | tail -n1)"
  printf '%s' "$pct"
}

# 1-minute load average scaled x100 as an integer (e.g. 3.27 -> 327).
# Robust to comma OR dot decimal separators.
ct_load1_x100() {
  local raw whole frac
  raw="$(LC_ALL=C sysctl -n vm.loadavg 2>/dev/null)" || return 0
  # raw looks like: { 3,27 2,81 4,17 }  or  { 3.27 2.81 4.17 }
  raw="$(printf '%s' "$raw" | LC_ALL=C tr -d '{}' | LC_ALL=C awk '{print $1}')"
  whole="$(printf '%s' "$raw" | LC_ALL=C grep -oE '^[0-9]+')"
  frac="$(printf '%s' "$raw" | LC_ALL=C sed -E 's/^[0-9]+[.,]?//; s/[^0-9].*$//')"
  [ -z "$whole" ] && return 0
  frac="${frac}00"; frac="${frac:0:2}"
  printf '%d' "$((10#$whole * 100 + 10#$frac))"
}

ct_cores() { LC_ALL=C sysctl -n hw.logicalcpu 2>/dev/null || echo 1; }

# ---- process tree: claude descendants ---------------------------------------
# Echo the PIDs of every claude process (the anchors) on this user's session.
# CT_ANCHOR_OVERRIDE (space-separated PIDs) forces a specific anchor set; used
# only by the test suite, never set in normal operation.
ct_claude_anchors() {
  if [ -n "${CT_ANCHOR_OVERRIDE:-}" ]; then
    printf '%s\n' $CT_ANCHOR_OVERRIDE | LC_ALL=C sort -u
    return 0
  fi
  { pgrep -x claude 2>/dev/null
    pgrep -f '/\.local/bin/claude$' 2>/dev/null
  } | LC_ALL=C sort -u
}

# Echo all PIDs that descend from any claude anchor (excluding the anchors
# themselves). Pure-bash BFS over the pid/ppid map — no external recursion.
ct_claude_descendants() {
  local anchors
  anchors="$(ct_claude_anchors)"
  [ -z "$anchors" ] && return 0

  # Build "pid ppid" lines once.
  local map
  map="$(LC_ALL=C ps -axo pid=,ppid= 2>/dev/null)"
  [ -z "$map" ] && return 0

  # frontier = anchors; expand level by level.
  local frontier="$anchors" seen="" next pid ppid line
  while [ -n "$frontier" ]; do
    next=""
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      pid="${line%% *}"
      ppid="${line##* }"
      # is ppid in the current frontier?
      case " $frontier " in
        *" $ppid "*)
          # avoid revisiting
          case " $seen " in
            *" $pid "*) : ;;
            *) seen="$seen $pid"; next="$next $pid" ;;
          esac
          ;;
      esac
    done <<EOF
$map
EOF
    frontier="$next"
  done
  # emit, trimmed, one per line
  printf '%s\n' $seen
}
