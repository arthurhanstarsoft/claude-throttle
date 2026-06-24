# Convenience installer for claude-throttle on Windows.
# Run from a normal (non-admin) PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'claude-throttle.ps1') install
