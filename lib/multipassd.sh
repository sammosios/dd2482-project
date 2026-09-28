#!/usr/bin/env bash
# Helpers for managing the multipass daemon itself on a macOS host, used by
# multipass-unsuspend.sh and multipass-reset.sh. The daemon runs as root
# under launchd, so everything here needs sudo. Sourced after lib/common.sh.
set -euo pipefail

MULTIPASSD_PLIST=/Library/LaunchDaemons/com.canonical.multipassd.plist
MULTIPASSD_LABEL=com.canonical.multipassd
MULTIPASS_SOCKET=/var/run/multipass_socket
MULTIPASS_BIN_DIR="/Library/Application Support/com.canonical.multipass/bin"
MULTIPASSD_DATA_DIR="/var/root/Library/Application Support/multipassd"
MULTIPASSD_CACHE_DIR="/var/root/Library/Caches/multipassd"
MULTIPASS_CLIENT_CERT_DIR="$HOME/Library/Application Support/multipass-client-certificate"

require_macos_multipassd() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo "this script only supports the macOS multipass install" >&2; exit 1; }
  [[ -f "$MULTIPASSD_PLIST" ]] || { echo "$MULTIPASSD_PLIST not found - is multipass installed?" >&2; exit 1; }
  # Prompt for the password once up front instead of halfway through.
  sudo -v
}

stop_multipassd() {
  # Unload the launchd job first: while it's loaded, launchd respawns the
  # daemon as soon as it dies, which is exactly what a crash-looping daemon
  # looks like. Then kill anything left over, including orphaned VMs.
  echo "== stopping multipassd"
  sudo launchctl bootout "system/$MULTIPASSD_LABEL" 2>/dev/null || true
  sudo pkill -f "$MULTIPASS_BIN_DIR/multipassd" 2>/dev/null || true
  sudo pkill -f "$MULTIPASS_BIN_DIR/qemu-system" 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    pgrep -f "$MULTIPASS_BIN_DIR/(multipassd|qemu-system)" >/dev/null || break
    sleep 1
  done
  sudo pkill -9 -f "$MULTIPASS_BIN_DIR/(multipassd|qemu-system)" 2>/dev/null || true
  sudo rm -f "$MULTIPASS_SOCKET"
}

start_multipassd() {
  # Waits until the daemon actually answers, not just until the socket file
  # exists - a crash-looping daemon recreates the socket every few seconds.
  echo "== starting multipassd"
  sudo launchctl bootstrap system "$MULTIPASSD_PLIST"
  local i
  for i in $(seq 1 60); do
    if multipass list >/dev/null 2>&1; then
      echo "== multipassd is up"
      return 0
    fi
    sleep 1
  done
  echo "multipassd did not come up within 60s; check: sudo tail -50 /Library/Logs/Multipass/multipassd.log" >&2
  return 1
}
