#!/usr/bin/env bash
# Deletes every VM this project created, for clean-slate reproducibility testing.
# Usage: local/teardown.sh [-y]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=local
source lib/common.sh

target_require

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

mapfile -t names < <(multipass list --format csv | awk -F, -v p="$PREFIX" 'NR>1 && $1 ~ "^"p"-" {print $1}')

if [[ ${#names[@]} -eq 0 ]]; then
  stop_forwarder
  echo "== no ${PREFIX}-* VMs found, nothing to tear down"
  exit 0
fi

echo "== will delete: ${names[*]}"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

multipass delete --purge "${names[@]}"

# Only does anything if forward.sh (gitignored, WSL-only) started forwarders - which
# would otherwise keep holding their ports, pointed at a control-plane IP
# that no longer exists.
stop_forwarder

# Everything in the local state belonged to the VMs that are now gone: an
# API key the next Dokploy would reject (so 01 would fail verification
# instead of cleanly re-provisioning), and credentials for a registry,
# OpenBao and web app database that no longer exist - the next run
# generates fresh ones. .dokploy-admin.env and .github-runner.env are NOT
# removed: they're config meant to be reused across rebuilds.
remove_local_state

echo "== teardown complete"
