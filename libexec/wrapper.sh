#!/usr/bin/env bash
# wrapper.sh — the subprocess that actually holds a concurrency slot.
#
# Invoked as:  claude-throttle run -- <original command string>
# Dispatched here with args:  -- <cmd>     (or, internally:  __held <marker> <cmd>)
#
# It grabs one of N `lockf` slots and holds it for the ENTIRE lifetime of the
# command (lockf keeps the lock until its child exits, and auto-releases it if we
# die for any reason). At most CT_MAX_CONCURRENCY commands run at once; the rest
# poll until a slot frees or CT_ACQUIRE_TIMEOUT elapses, after which the command
# runs unthrottled rather than ever blocking Claude forever.

set +e
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_here/common.sh"

LOCKF="${CT_LOCKF:-/usr/bin/lockf}"

# ---- internal re-entry: we hold the lock, now run the command ----------------
# Called by lockf as:  wrapper.sh __held <marker> <cmd>
if [ "$1" = "__held" ]; then
  marker="$2"; ORIG="$3"
  : >"$marker" 2>/dev/null            # signal the parent that we actually started
  if [ "${CT_USE_CPULIMIT:-0}" = "1" ] && command -v cpulimit >/dev/null 2>&1; then
    # cpulimit must supervise the child, so we can't exec; forward signals.
    nice -n "${CT_NICE:-10}" cpulimit --limit "${CT_CPULIMIT_PCT:-300}" -- \
      bash -c "$ORIG" &
    child=$!
    trap 'kill -TERM "$child" 2>/dev/null' INT TERM
    wait "$child"; exit $?
  fi
  exec nice -n "${CT_NICE:-10}" bash -c "$ORIG"
fi

# ---- normal entry: parse the original command -------------------------------
[ "$1" = "--" ] && shift
ORIG="$1"
if [ -z "$ORIG" ]; then
  ct_tlog "RUN empty command, nothing to do"
  exit 0
fi

# Disabled -> run straight through, no throttling.
if [ "${CT_ENABLED:-1}" != "1" ]; then
  exec bash -c "$ORIG"
fi

# lockf missing -> can't throttle; run unthrottled (fail-open).
if [ ! -x "$LOCKF" ]; then
  ct_tlog "RUN lockf missing, running unthrottled: $ORIG"
  exec bash -c "$ORIG"
fi

self="$_here/wrapper.sh"

# ---- optional pre-start memory gate -----------------------------------------
if [ "${CT_PRESTART_WAIT:-1}" = "1" ]; then
  pre_deadline=$(( $(LC_ALL=C date +%s) + ${CT_PRESTART_TIMEOUT:-60} ))
  while :; do
    free="$(ct_free_pct)"
    [ -z "$free" ] && break                              # can't read -> don't gate
    [ "$free" -ge "${CT_RESUME_FREE_PCT:-25}" ] && break # enough headroom
    [ "$(LC_ALL=C date +%s)" -ge "$pre_deadline" ] && { ct_tlog "PRESTART timeout (free=${free}%): $ORIG"; break; }
    sleep 0.5
  done
fi

# ---- acquire a slot ---------------------------------------------------------
deadline=$(( $(LC_ALL=C date +%s) + ${CT_ACQUIRE_TIMEOUT:-300} ))

while :; do
  # Recompute the limit each pass so it tracks current free memory: if RAM frees
  # up while we wait, more slots open; if it tightens, fewer new commands start.
  N="$(ct_effective_concurrency)"
  i=1
  while [ "$i" -le "$N" ]; do
    slot="$CT_SLOTS_DIR/slot.$i.lock"
    marker="$CT_SLOTS_DIR/.started.$$.$i"
    rm -f "$marker" 2>/dev/null
    # -s silent, -t 0 non-blocking. Returns 75 (EX_TEMPFAIL) if the slot is busy;
    # otherwise returns the command's own exit status.
    "$LOCKF" -st 0 "$slot" "$self" __held "$marker" "$ORIG"
    rc=$?
    if [ -f "$marker" ]; then
      # Our command actually started -> rc is its real exit code.
      rm -f "$marker" 2>/dev/null
      ct_tlog "RAN slot=$i rc=$rc: $ORIG"
      exit "$rc"
    fi
    rm -f "$marker" 2>/dev/null
    # Slot was busy (rc should be 75); try the next one.
    i=$((i + 1))
  done

  # All slots busy. Bail to unthrottled execution if we've waited too long.
  if [ "$(LC_ALL=C date +%s)" -ge "$deadline" ]; then
    ct_tlog "SLOT_TIMEOUT_FALLBACK running unthrottled: $ORIG"
    exec bash -c "$ORIG"
  fi

  # Poll again after a short, jittered delay (avoid thundering-herd on slot 1).
  nap="$(LC_ALL=C awk -v b="${CT_POLL:-0.3}" -v j="$((RANDOM % 300))" 'BEGIN{printf "%.3f", b + j/1000}')"
  sleep "$nap"
done
