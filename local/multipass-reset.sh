#!/usr/bin/env bash
# Wipes ALL multipass state on this host - every VM (not just this project's),
# every disk, cached images, the socket and the client certificate - then
# starts the daemon fresh. The last resort when multipassd won't come up and
# multipass-unsuspend.sh didn't help. Binaries are untouched, so no reinstall
# is needed. macOS only.
# Usage: local/multipass-reset.sh [-y]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=local
source lib/common.sh
source local/lib/multipassd.sh

target_require

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

echo "== this deletes EVERY multipass VM on this machine, including non-${PREFIX} ones"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

require_macos_multipassd

# Stopped first so launchd can't respawn it while its state is being removed.
stop_multipassd

echo "== removing daemon state"
sudo rm -rf "$MULTIPASSD_DATA_DIR" "$MULTIPASSD_CACHE_DIR"
# The fresh daemon won't know the old client cert, so let the client
# generate a new one on first connect.
rm -rf "$MULTIPASS_CLIENT_CERT_DIR"

# Same as teardown.sh: the VMs these belonged to are gone.
stop_forwarder
remove_local_state

start_multipassd
echo "== reset complete - run local/bootstrap.sh to rebuild the cluster"
