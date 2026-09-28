#!/usr/bin/env bash
# Deletes this machine's state for the remote cluster (.state/remote/: the
# Dokploy API key, the registry, OpenBao and web app credentials). Run it
# after the servers were destroyed or reprovisioned, so the next
# remote/bootstrap.sh starts clean instead of failing on a stale API key.
# The servers themselves are never touched: creating and destroying them is
# the provisioner's job, not this chain's. Don't run it against a cluster
# that still exists - OpenBao's root token can't be recovered afterwards.
# Usage: remote/forget.sh [-y]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -d .state/remote ]] && [[ -n "$(ls -A .state/remote)" ]] \
  || { echo "== no remote state, nothing to forget"; exit 0; }

echo "== will delete: $(cd .state/remote && ls -A | tr '\n' ' ')"
if [[ "${1:-}" != "-y" ]]; then
  read -r -p "proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi
rm -rf .state/remote
echo "== forgot the remote cluster"
