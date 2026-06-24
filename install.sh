#!/usr/bin/env bash
# Convenience wrapper: installs claude-throttle on this machine.
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$here/bin/claude-throttle" install
