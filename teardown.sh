#!/usr/bin/env bash
# Deletes every VM this project created, for clean-slate reproducibility testing.
# Usage: ./teardown.sh [-y]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

require multipass

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

# Only does anything if forward.sh (gitignored, WSL-only) ever started a
# forwarder - which would otherwise keep holding its port, pointed at a
# control-plane IP that no longer exists.
stop_forwarder

# The API key is tied to the specific Dokploy instance that issued it - once
# its control-plane VM is gone, the key is dead weight that just causes
# 01-dokploy-api-key.sh to fail verification against whatever gets built
# next instead of cleanly re-provisioning. .dokploy-admin.env is NOT
# removed - those are just admin credentials meant to be reused across
# rebuilds, not tied to any one instance.
if [[ -f "$API_KEY_FILE" ]]; then
  rm -f "$API_KEY_FILE"
  echo "== removed stale $API_KEY_FILE"
fi

echo "== teardown complete"
