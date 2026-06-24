#!/usr/bin/env bash
# stress.sh — prove the concurrency semaphore caps simultaneous heavy commands.
#
# Launches JOBS wrappers, each running a fake "heavy" command that records its
# start/stop around a short sleep. Afterwards we compute the peak number that
# overlapped in time and assert it never exceeded CT_MAX_CONCURRENCY.
#
# Uses an isolated state dir so it never touches your real slots/logs.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

JOBS="${JOBS:-6}"
N="${N:-2}"            # concurrency to enforce/expect
HOLD="${HOLD:-2}"      # seconds each fake command "works"

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-stress.XXXXXX")"
export CT_STATE_DIR="$work/state"
export CT_CONFIG_FILE="$work/none.sh"     # force built-in defaults
export CT_DYNAMIC=0                        # fixed cap so the assertion is deterministic
export CT_MAX_CONCURRENCY="$N"
export CT_ACQUIRE_TIMEOUT=60
export CT_PRESTART_WAIT=0                  # don't gate on real memory during the test
events="$work/events"; : >"$events"
mkdir -p "$CT_STATE_DIR"

echo "stress: JOBS=$JOBS concurrency=$N hold=${HOLD}s  (state=$CT_STATE_DIR)"

# Each job: a single command string that brackets a sleep with +/- markers.
for j in $(seq 1 "$JOBS"); do
  cmd="echo +$j >>'$events'; sleep $HOLD; echo -$j >>'$events'"
  bash "$root/bin/claude-throttle" run -- "$cmd" &
done
wait

# Replay the +/- event log to find peak concurrency.
peak=0; cur=0
while IFS= read -r line; do
  case "$line" in
    +*) cur=$((cur + 1)); [ "$cur" -gt "$peak" ] && peak="$cur" ;;
    -*) cur=$((cur - 1)) ;;
  esac
done <"$events"

echo "peak concurrency observed: $peak (limit $N)"
rm -rf "$work"
if [ "$peak" -le "$N" ] && [ "$peak" -ge 1 ]; then
  echo "PASS: concurrency stayed within the limit"
  exit 0
else
  echo "FAIL: peak $peak exceeded limit $N"
  exit 1
fi
