#!/usr/bin/env bash
# linux/platform.sh — Linux-specific implementation of the platform interface.
# Sourced by shared/common.sh. Mirrors macos/platform.sh using /proc, flock,
# tac, and a systemd --user service (with a nohup fallback).

# ---- service paths/labels (systemd --user) ----------------------------------
CT_SERVICE_NAME="claude-throttle.service"
CT_SERVICE_UNIT="$HOME/.config/systemd/user/$CT_SERVICE_NAME"

# ---- metrics (LC_ALL=C, integers only) --------------------------------------
# Free system memory %. Uses MemAvailable (kernel's estimate of reclaimable
# memory: free + reclaimable cache/slab) — the right analog to macOS "free %",
# far better than MemFree which undercounts because Linux uses RAM for cache.
ct_free_pct() {
  local avail total
  avail="$(LC_ALL=C awk '/^MemAvailable:/{print $2; f=1} END{exit !f}' /proc/meminfo 2>/dev/null)" \
    || avail="$(LC_ALL=C awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)"
  total="$(LC_ALL=C awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  [ -n "$avail" ] && [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null || return 0
  printf '%d' "$(( avail * 100 / total ))"
}

ct_total_mem_mb() {                 # /proc/meminfo values are in kB
  local kb; kb="$(LC_ALL=C awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)" || return 0
  [ -n "$kb" ] && printf '%d' "$(( kb / 1024 ))"
}

# 1-minute load average x100. /proc/loadavg always uses dot decimals (locale-free).
ct_load1_x100() {
  local raw whole frac
  raw="$(LC_ALL=C awk '{print $1}' /proc/loadavg 2>/dev/null)" || return 0
  whole="${raw%%.*}"; frac="${raw#*.}"
  [ -z "$whole" ] && return 0
  [ "$frac" = "$raw" ] && frac=0
  frac="${frac}00"; frac="${frac:0:2}"
  printf '%d' "$(( 10#$whole * 100 + 10#$frac ))"
}

ct_cores() { LC_ALL=C nproc 2>/dev/null || LC_ALL=C getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }

# ---- concurrency slot lock --------------------------------------------------
# util-linux `flock -n <file> <cmd...>` acquires a non-blocking lock, runs <cmd>
# while holding it, releases on exit. Busy returns 1 — irrelevant, the wrapper
# detects an actual run via its marker file.
ct_lock_available() { command -v flock >/dev/null 2>&1; }
ct_slot_run() { flock -n "$@"; }

# ---- watchdog singleton -----------------------------------------------------
# Hold an flock on a side file for our whole lifetime via fd 9.
ct_singleton_acquire() {
  local pidfile="$1"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$pidfile.lock" || return 1
    flock -n 9 || return 1
    echo $$ >"$pidfile"
    return 0
  fi
  # Fallback: pidfile liveness check.
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    return 1
  fi
  echo $$ >"$pidfile"
}

# ---- pausable-process exclusion ---------------------------------------------
# Never SIGSTOP these. Login shells are intentionally NOT excluded (heavy build
# steps run under a shell that is a real claude descendant we DO want pausable);
# the RSS floor protects idle interactive shells.
ct_excluded_comm() {
  case "$1" in
    claude|claude-throttle) return 0 ;;
    Xorg|Xwayland|*wayland*|gnome-shell|kwin_x11|kwin_wayland|plasmashell|mutter|gdm*|sddm*) return 0 ;;
    systemd|systemd-*|init|dbus-daemon|dbus-broker|*logind) return 0 ;;
    sshd|NetworkManager|pulseaudio|pipewire|pipewire-pulse|wireplumber) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- reverse a file's lines -------------------------------------------------
ct_reverse() { tac "$1" 2>/dev/null || LC_ALL=C tail -r "$1" 2>/dev/null || cat "$1" 2>/dev/null; }

# ---- service management (systemd --user, with fallback) ---------------------
ct_service_artifact_path() { printf '%s' "$CT_SERVICE_UNIT"; }
ct_service_artifact_name() { printf '%s' "systemd --user unit"; }

# True if a usable per-user systemd instance is reachable.
ct_systemd_user_ok() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

ct_service_install() {
  mkdir -p "$(dirname "$CT_SERVICE_UNIT")" 2>/dev/null
  local template="$CT_INSTALL_DIR/linux/$CT_SERVICE_NAME.template"
  sed -e "s#__CT_BIN__#$CT_INSTALL_BIN#g" -e "s#__CT_WATCHDOG_LOG__#$CT_WATCHDOG_LOG#g" \
      "$template" >"$CT_SERVICE_UNIT" && ok "wrote $CT_SERVICE_UNIT"
  if ct_systemd_user_ok; then
    systemctl --user daemon-reload >/dev/null 2>&1
    if systemctl --user enable --now "$CT_SERVICE_NAME" >/dev/null 2>&1; then
      ok "watchdog enabled (systemctl --user)"
      command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$USER" >/dev/null 2>&1 \
        && ok "lingering enabled (runs without an active session)" \
        || warn "could not enable lingering — watchdog stops at logout (loginctl enable-linger $USER)"
    else
      warn "systemctl --user enable failed; falling back to background process"
      ct_service_install_fallback
    fi
  else
    warn "systemd --user not available; using background-process fallback"
    ct_service_install_fallback
  fi
}

# Fallback when systemd --user is unavailable (containers, WSL without systemd,
# minimal distros): start now via nohup, and re-launch at login from the profile.
ct_service_install_fallback() {
  nohup "$CT_INSTALL_BIN" watchdog >/dev/null 2>&1 &
  ok "started watchdog (nohup, no auto-restart on crash)"
  local prof="$HOME/.profile"; [ -n "${ZDOTDIR:-}${ZSH_VERSION:-}" ] && prof="$HOME/.zprofile"
  local marker="# >>> claude-throttle watchdog >>>"
  if ! grep -qF "$marker" "$prof" 2>/dev/null; then
    {
      printf '%s\n' "$marker"
      printf '%s\n' 'command -v claude-throttle >/dev/null 2>&1 && { claude-throttle status 2>/dev/null | grep -q RUNNING || nohup claude-throttle watchdog >/dev/null 2>&1 & }'
      printf '%s\n' "# <<< claude-throttle watchdog <<<"
    } >>"$prof" && ok "added login launcher to $prof"
  fi
}

ct_service_uninstall() {
  if ct_systemd_user_ok; then
    systemctl --user disable --now "$CT_SERVICE_NAME" >/dev/null 2>&1
    systemctl --user daemon-reload >/dev/null 2>&1
  fi
  [ -f "$CT_WATCHDOG_PID" ] && kill -TERM "$(cat "$CT_WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
  rm -f "$CT_SERVICE_UNIT" && ok "removed $CT_SERVICE_UNIT"
  # Remove the fallback login launcher block if present.
  for prof in "$HOME/.profile" "$HOME/.zprofile"; do
    [ -f "$prof" ] && LC_ALL=C sed -i.bak '/# >>> claude-throttle watchdog >>>/,/# <<< claude-throttle watchdog <<</d' "$prof" 2>/dev/null
  done
}

ct_service_reload() { ct_systemd_user_ok && systemctl --user restart "$CT_SERVICE_NAME" >/dev/null 2>&1; }
ct_service_status() { ct_systemd_user_ok && systemctl --user is-active "$CT_SERVICE_NAME" >/dev/null 2>&1; }

# ---- doctor dependency rows -------------------------------------------------
ct_doctor_platform() {
  ct_lock_available && ok "flock present" || bad "flock MISSING — throttle slots fall back to unthrottled (install util-linux)"
  have jq && ok "jq present" || bad "jq MISSING — hook fails open (no throttling)"
  have tac && ok "tac present" || warn "tac absent (resume order falls back)"
  have cpulimit && ok "cpulimit present" || warn "cpulimit absent (optional)"
  if ct_systemd_user_ok; then ok "systemd --user reachable"; else warn "systemd --user unavailable — using login/nohup fallback (no crash auto-restart)"; fi
  if LC_ALL=C ps --version 2>&1 | grep -qi busybox; then warn "busybox ps detected — watchdog process detection degraded; install procps"; fi
}
