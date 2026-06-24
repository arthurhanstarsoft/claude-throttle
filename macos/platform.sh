#!/usr/bin/env bash
# macos/platform.sh — macOS-specific implementation of the platform interface.
# Sourced by shared/common.sh. Provides: metrics, the slot lock, the watchdog
# singleton, the pausable-process exclusion list, file reversal, and service
# (launchd) management. See linux/platform.sh for the Linux counterpart.

# ---- service paths/labels (launchd) -----------------------------------------
CT_PLIST_LABEL="com.user.claude-throttle.watchdog"
CT_PLIST="$HOME/Library/LaunchAgents/$CT_PLIST_LABEL.plist"

# ---- metrics (LC_ALL=C, integers only) --------------------------------------
# Free system memory as an integer percentage (0-100). Echoes "" on failure.
ct_free_pct() {
  local line pct
  line="$(LC_ALL=C memory_pressure 2>/dev/null | grep -i 'free percentage')" || return 0
  # e.g. "System-wide memory free percentage: 39%"
  pct="$(printf '%s' "$line" | LC_ALL=C grep -oE '[0-9]+' | tail -n1)"
  printf '%s' "$pct"
}

# 1-minute load average x100 (3.27 -> 327). macOS sysctl may use comma decimals.
ct_load1_x100() {
  local raw whole frac
  raw="$(LC_ALL=C sysctl -n vm.loadavg 2>/dev/null)" || return 0
  # raw: { 3,27 2,81 4,17 } or { 3.27 2.81 4.17 }
  raw="$(printf '%s' "$raw" | LC_ALL=C tr -d '{}' | LC_ALL=C awk '{print $1}')"
  whole="$(printf '%s' "$raw" | LC_ALL=C grep -oE '^[0-9]+')"
  frac="$(printf '%s' "$raw" | LC_ALL=C sed -E 's/^[0-9]+[.,]?//; s/[^0-9].*$//')"
  [ -z "$whole" ] && return 0
  frac="${frac}00"; frac="${frac:0:2}"
  printf '%d' "$((10#$whole * 100 + 10#$frac))"
}

ct_cores() { LC_ALL=C sysctl -n hw.logicalcpu 2>/dev/null || echo 1; }

ct_total_mem_mb() {
  local b; b="$(LC_ALL=C sysctl -n hw.memsize 2>/dev/null)" || return 0
  [ -n "$b" ] && printf '%d' "$(( b / 1048576 ))"
}

# ---- concurrency slot lock --------------------------------------------------
# macOS ships /usr/bin/lockf (BSD). `lockf -st 0 <file> <cmd...>` acquires a
# non-blocking lock, runs <cmd> while holding it, and releases on exit. Returns
# 75 (EX_TEMPFAIL) when the slot is busy — but the wrapper detects an actual run
# via its marker file, so the busy return code is irrelevant.
CT_LOCKF="${CT_LOCKF:-/usr/bin/lockf}"
ct_lock_available() { [ -x "$CT_LOCKF" ]; }
ct_slot_run() { "$CT_LOCKF" -st 0 "$@"; }

# ---- watchdog singleton -----------------------------------------------------
ct_singleton_acquire() {
  local pidfile="$1"
  if command -v shlock >/dev/null 2>&1; then
    shlock -f "$pidfile" -p $$ >/dev/null 2>&1
    return
  fi
  # Fallback: pidfile with liveness check.
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  echo $$ >"$pidfile"
}

# ---- pausable-process exclusion ---------------------------------------------
# Never SIGSTOP these even if they show up as claude descendants.
ct_excluded_comm() {
  case "$1" in
    claude|claude-throttle|*WindowServer*|*loginwindow*|coreaudiod|kernel_task|launchd|*Terminal*|*iTerm*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- reverse a file's lines -------------------------------------------------
ct_reverse() { LC_ALL=C tail -r "$1" 2>/dev/null || cat "$1" 2>/dev/null; }

# ---- service management (launchd) -------------------------------------------
ct_service_artifact_path() { printf '%s' "$CT_PLIST"; }
ct_service_artifact_name() { printf '%s' "LaunchAgent plist"; }

ct_service_install() {
  mkdir -p "$HOME/Library/LaunchAgents" 2>/dev/null
  local template="$CT_INSTALL_DIR/macos/$CT_PLIST_LABEL.plist.template"
  local tmp="$CT_PLIST.tmp.$$"
  sed -e "s#__CT_BIN__#$CT_INSTALL_BIN#g" -e "s#__CT_WATCHDOG_LOG__#$CT_WATCHDOG_LOG#g" \
      "$template" >"$tmp" && mv "$tmp" "$CT_PLIST" && ok "wrote $CT_PLIST"
  # bootout is async; wait before bootstrap so a reinstall doesn't race itself.
  launchctl bootout "gui/$(id -u)/$CT_PLIST_LABEL" >/dev/null 2>&1
  sleep 1
  if launchctl bootstrap "gui/$(id -u)" "$CT_PLIST" >/dev/null 2>&1; then
    ok "watchdog loaded (launchctl bootstrap)"
  elif launchctl load -w "$CT_PLIST" >/dev/null 2>&1; then
    ok "watchdog loaded (launchctl load)"
  else
    warn "could not load watchdog via launchctl — start manually: claude-throttle watchdog &"
  fi
}

ct_service_uninstall() {
  launchctl bootout "gui/$(id -u)/$CT_PLIST_LABEL" >/dev/null 2>&1
  launchctl unload -w "$CT_PLIST" >/dev/null 2>&1
  [ -f "$CT_WATCHDOG_PID" ] && kill -TERM "$(cat "$CT_WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
  rm -f "$CT_PLIST" && ok "removed $CT_PLIST"
}

ct_service_reload() { ct_service_install; }
ct_service_status() { launchctl print "gui/$(id -u)/$CT_PLIST_LABEL" >/dev/null 2>&1; }

# ---- doctor dependency rows -------------------------------------------------
ct_doctor_platform() {
  ct_lock_available && ok "lockf present ($CT_LOCKF)" || bad "lockf MISSING — throttle slots fall back to unthrottled"
  have jq && ok "jq present" || bad "jq MISSING — hook fails open (no throttling)"
  have cpulimit && ok "cpulimit present" || warn "cpulimit absent (optional; \`brew install cpulimit\` to enable CT_USE_CPULIMIT)"
  have shlock && ok "shlock present" || warn "shlock absent (watchdog uses pidfile fallback)"
}
