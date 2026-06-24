#!/usr/bin/env bash
# selftest.sh — fast checks for parsers, the hook rewrite, exit-code propagation,
# and the kill switch. No real system load; safe to run anytime.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
bin="$root/bin/claude-throttle"

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-self.XXXXXX")"
export CT_STATE_DIR="$work/state"
export CT_CONFIG_FILE="$work/none.sh"
export CT_PRESTART_WAIT=0
mkdir -p "$CT_STATE_DIR"

pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1));
  else echo "  FAIL: $1 (expected [$2], got [$3])"; fail=$((fail+1)); fi
}
contains() { # contains <name> <needle> <haystack>
  case "$3" in *"$2"*) echo "  ok: $1"; pass=$((pass+1));;
    *) echo "  FAIL: $1 (missing [$2] in [$3])"; fail=$((fail+1));; esac
}

echo "metric parsers:"
. "$root/libexec/common.sh"
fp="$(ct_free_pct)";  echo "  free_pct=[$fp]";    [ -n "$fp" ] && case "$fp" in (*[!0-9]*) echo "  FAIL: free_pct not integer"; fail=$((fail+1));; (*) pass=$((pass+1));; esac
l1="$(ct_load1_x100)"; echo "  load1x100=[$l1]";  case "$l1" in (*[!0-9]*) echo "  FAIL: load not integer"; fail=$((fail+1));; ("") echo "  FAIL: load empty"; fail=$((fail+1));; (*) pass=$((pass+1));; esac

echo "hook rewrite:"
out="$(printf '%s' '{"tool_input":{"command":"pnpm install"}}' | bash "$bin" hook)"
contains "heavy command wrapped" "run -- 'pnpm install'" "$out"
out2="$(printf '%s' '{"tool_input":{"command":"ls -la"}}' | bash "$bin" hook)"
check "trivial command not wrapped (empty output)" "" "$out2"
out3="$(printf '%s' '{"tool_input":{"command":"claude-throttle run -- '\''npm test'\''"}}' | bash "$bin" hook)"
check "already-wrapped not double-wrapped" "" "$out3"
# Tricky quoting: command containing single quotes must survive the rewrite.
out4="$(printf '%s' '{"tool_input":{"command":"npm test '\''a b'\''"}}' | bash "$bin" hook)"
contains "quotes preserved in rewrite" "run -- " "$out4"

echo "wrapper exit-code propagation:"
bash "$bin" run -- "exit 7"; check "propagates exit 7" "7" "$?"
bash "$bin" run -- "true";   check "propagates exit 0" "0" "$?"

echo "kill switch:"
out5="$(CT_ENABLED=0 bash -c "printf '%s' '{\"tool_input\":{\"command\":\"pnpm install\"}}' | bash '$bin' hook")"
check "disabled hook outputs nothing" "" "$out5"

rm -rf "$work"
echo
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
