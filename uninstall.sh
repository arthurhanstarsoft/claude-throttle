#!/usr/bin/env bash
# Convenience wrapper: removes claude-throttle from this machine.
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$here/bin/claude-throttle" uninstall
