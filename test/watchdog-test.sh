#!/usr/bin/env bash
# watchdog-test.sh — prove the watchdog pauses (SIGSTOP) a heavy claude
# descendant when memory is "critical" and resumes (SIGCONT) it on cleanup.
#
# We don't actually starve the machine: we force the critical branch with
# CT_CRIT_FREE_PCT=100 and point the watchdog at a controlled victim tree via
# CT_ANCHOR_OVERRIDE (a test-only seam). The victim is a real ~220 MB process so
# it clears the RSS floor.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pstate() { LC_ALL=C ps -o state= -p "$1" 2>/dev/null | cut -c1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-wd.XXXXXX")"
mkdir -p "$work/state"

# Victim tree: an "anchor" shell whose child holds ~220 MB. The child is the
# pausable descendant; the anchor itself is excluded (anchors are never paused).
bash -c 'perl -e "\$x = \"A\" x (220*1024*1024); sleep 600;" & echo $! > "'"$work"'/victim.pid"; wait' &
anchor=$!
# wait for the victim pid file
for _ in $(seq 1 20); do [ -s "$work/victim.pid" ] && break; sleep 0.2; done
victim="$(cat "$work/victim.pid" 2>/dev/null)"
echo "anchor=$anchor victim=$victim victim_state=$(pstate "$victim")"

fail=0
[ -n "$victim" ] || { echo "FAIL: victim did not start"; kill $anchor 2>/dev/null; rm -rf "$work"; exit 1; }

# Run the watchdog: always-critical, never-auto-resume, act on first tick.
CT_STATE_DIR="$work/state" CT_CONFIG_FILE="$work/none.sh" \
CT_ANCHOR_OVERRIDE="$anchor" \
CT_CRIT_FREE_PCT=100 CT_RESUME_FREE_PCT=101 CT_CRIT_SUSTAIN=1 \
CT_WATCHDOG_INTERVAL=1 CT_MIN_PAUSE_RSS_MB=150 CT_PAUSE_COUNT=2 \
  bash "$root/bin/claude-throttle" watchdog &
wd=$!

# Wait for the victim to be stopped (state T).
for _ in $(seq 1 20); do [ "$(pstate "$victim")" = "T" ] && break; sleep 0.3; done
st="$(pstate "$victim")"
if [ "$st" = "T" ]; then echo "ok: victim paused (state=T)"; else echo "FAIL: victim not paused (state=$st)"; fail=1; fi
echo "--- watchdog.log ---"; cat "$work/state/watchdog.log"

# Stopping the watchdog must SIGCONT everything it paused (cleanup trap).
kill -TERM $wd 2>/dev/null; wait $wd 2>/dev/null
for _ in $(seq 1 20); do [ "$(pstate "$victim")" != "T" ] && break; sleep 0.3; done
st2="$(pstate "$victim")"
if [ "$st2" != "T" ] && [ -n "$st2" ]; then echo "ok: victim resumed on cleanup (state=$st2)"; else echo "FAIL: victim still stopped (state=$st2)"; fail=1; fi

kill $anchor "$victim" 2>/dev/null
rm -rf "$work"
echo
[ "$fail" -eq 0 ] && { echo "watchdog-test: PASS"; exit 0; } || { echo "watchdog-test: FAIL"; exit 1; }
