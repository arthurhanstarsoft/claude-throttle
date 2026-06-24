#!/usr/bin/env bash
# hook-pretooluse.sh — Claude Code PreToolUse hook for the Bash tool.
#
# Reads the tool-call JSON on stdin and, for "heavy" commands, rewrites them to
# run through `claude-throttle run -- <cmd>` (Layer 1). Emits the rewrite via the
# PreToolUse `updatedInput` field.
#
# FAIL-OPEN by contract: on ANY problem (disabled, missing jq, bad JSON, gated
# out, already wrapped) we exit 0 with NO stdout, which tells Claude Code to run
# the original command unchanged. The throttle must never break Claude's ability
# to run a command.

set +e
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_here/common.sh"

allow_unchanged() { exit 0; }   # no stdout => original command runs as-is

# Master switch off -> do nothing.
[ "${CT_ENABLED:-1}" = "1" ] || allow_unchanged

# jq is required to read/emit JSON safely; without it, fail open.
command -v jq >/dev/null 2>&1 || allow_unchanged

input="$(cat 2>/dev/null)"
[ -n "$input" ] || allow_unchanged

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || allow_unchanged

# Idempotency: never double-wrap a command we already routed.
case "$cmd" in
  *"claude-throttle run "*) allow_unchanged ;;
esac

# Gate: in "heavy" mode only wrap resource-intensive commands.
if [ "${CT_GATE_MODE:-heavy}" = "heavy" ]; then
  if ! printf '%s' "$cmd" | LC_ALL=C grep -Eq "$CT_HEAVY_REGEX"; then
    allow_unchanged
  fi
fi

# Resolve the CLI path we route through. Prefer the installed symlink on PATH so
# the rewritten command works regardless of cwd; fall back to our absolute bin.
runner="claude-throttle"
if ! command -v claude-throttle >/dev/null 2>&1; then
  runner="$CT_ROOT/bin/claude-throttle"
fi

# Build:  <runner> run -- <original command, single-quoted safely>
# jq's @sh quoting handles arbitrary content (quotes, $, backticks, newlines).
wrapped="$(jq -rn --arg r "$runner" --arg c "$cmd" '$r + " run -- " + ($c|@sh)')"
[ -n "$wrapped" ] || allow_unchanged

jq -cn --arg c "$wrapped" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: { command: $c }
  }
}' 2>/dev/null || allow_unchanged

ct_tlog "HOOK wrapped: $cmd"
exit 0
