#!/usr/bin/env bash
# Re-install claude-throttle from this repo after you've edited it: copies the
# latest code into the install location and reloads the watchdog. Your config in
# ~/.config/claude-throttle is preserved. Equivalent to `claude-throttle update`.
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$here/bin/claude-throttle" update
