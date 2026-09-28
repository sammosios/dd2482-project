#!/usr/bin/env bash
# Installs Dokploy on an already-provisioned control plane host over ssh
# (its installer runs `docker swarm init` itself). The remote counterpart of
# local/00-launch-cp-vm.sh: the same end state, minus creating the machine,
# plus the port guard (remote/node/dokploy-port-guard), applied before
# Dokploy starts so its ports are never open to the network. Like
# local/00, deliberately does NOT authenticate against Dokploy's API - see
# steps/01-dokploy-api-key.sh. Workers are joined separately by
# 02-join-workers.sh.
#
# The host needs a fresh Ubuntu 24.04, ssh access as SSH_USER with
# passwordless sudo, and nothing else on ports 80, 443 and 3000. See
# remote/hosts.env.example.
# Safe to re-run: never reinstalls a Dokploy that's already there.
# Usage: remote/00-install-dokploy.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=remote
source lib/common.sh
source remote/lib/prepare.sh

require curl
target_require
node_wait_ready "$(cp_node)"
load_cp

swarm_addr="$(cp_swarm_addr)"
check_swarm_iface "$CP_NODE" "$swarm_addr"
install_port_guard "$CP_NODE" "$swarm_addr"
install_dokploy
check_container_dns "$CP_NODE"

echo "== Dokploy is up on $CP_NODE ($CP_IP), swarm address $swarm_addr"
echo "==   its UI: $(cp_ui_hint "$DOKPLOY_PORT" /)"
echo "== next: remote/01-dokploy-api-key.sh"
