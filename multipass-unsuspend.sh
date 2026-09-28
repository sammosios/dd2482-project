#!/usr/bin/env bash
# Recovers a multipass daemon stuck in a crash loop because a VM's suspend
# state can't be restored - QEMU aborts on start (e.g. "cpu_pre_load:
# assertion failed"), usually after a macOS or multipass upgrade, and the
# client only ever sees "cannot connect to the multipass socket".
#
# Deletes the "suspend" snapshot from every instance image, so each VM does a
# normal cold boot instead. VMs and their disks are kept; only the RAM state
# of suspended VMs is lost. macOS only. For a full wipe: multipass-reset.sh.
# Usage: ./multipass-unsuspend.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
source lib/multipassd.sh

require multipass
require_macos_multipassd

QEMU_IMG="$MULTIPASS_BIN_DIR/qemu-img"
[[ -x "$QEMU_IMG" ]] || { echo "$QEMU_IMG not found" >&2; exit 1; }

# The daemon has to be down: qemu-img needs the images unlocked.
stop_multipassd

found=0
while IFS= read -r -d '' img; do
  if sudo "$QEMU_IMG" snapshot -l "$img" | awk 'NR>2 {print $2}' | grep -qx suspend; then
    echo "== dropping suspend state from $img"
    sudo "$QEMU_IMG" snapshot -d suspend "$img"
    found=1
  fi
done < <(sudo find "$MULTIPASSD_DATA_DIR/qemu/vault/instances" -name '*.img' -print0 2>/dev/null)

[[ "$found" -eq 1 ]] || echo "== no suspended instances found"

start_multipassd
multipass list
