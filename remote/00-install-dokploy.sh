#!/usr/bin/env bash
# Installs Dokploy on an already-provisioned control plane host over ssh
# (its installer runs `docker swarm init` itself). The remote counterpart of
# local/00-launch-cp-vm.sh: the same end state, minus creating the machine.
# Like it, deliberately does NOT authenticate against Dokploy's API - see
# steps/01-dokploy-api-key.sh. Workers are joined separately by
# 02-join-workers.sh.
#
# The host needs Ubuntu (or another distro Dokploy's installer supports),
# ssh access as SSH_USER with passwordless sudo, and nothing else on ports
# 80, 443 and 3000. See remote/hosts.env.example for the ports this machine
# and the workers must be able to reach.
# Usage: remote/00-install-dokploy.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=remote
source lib/common.sh

require curl
target_require
load_cp
node_wait_ready "$CP_NODE"
install_dokploy

echo "== Dokploy is up at http://${CP_IP}:${DOKPLOY_PORT}"
echo "== next: remote/01-dokploy-api-key.sh (one-time manual admin-account step)"
