#!/usr/bin/env bash
# Launches the control-plane VM and installs Dokploy on it (its installer
# runs `docker swarm init` itself, so no manual swarm bootstrap here). Gets
# the control plane to a fully running state; deliberately does NOT
# authenticate against Dokploy's API - see steps/01-dokploy-api-key.sh,
# since Dokploy has no headless way to create its first admin account.
# Worker VMs are launched (and joined) separately by 02-launch-worker-vms.sh,
# once the control plane is authenticated - that split is what lets scaling
# out the cluster later be a single command against an already-running
# control plane.
# Usage: local/00-launch-cp-vm.sh [--cpus N] [--mem SIZE] [--disk SIZE]
#   --mem/--disk set CP_MEM (default 4G) / CP_DISK (default 30G), not the
#   workers' MEM / DISK.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=local
source lib/common.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus) CPUS="$2"; shift 2 ;;
    --mem) CP_MEM="$2"; shift 2 ;;
    --disk) CP_DISK="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

require curl
target_require

launch_vm "$CP_NAME" "$CP_DISK" "$CP_MEM"
load_cp
install_dokploy
check_container_dns "$CP_NODE"

echo "== Dokploy is up at http://${CP_IP}:${DOKPLOY_PORT}"
echo "== next: local/01-dokploy-api-key.sh (one-time manual admin-account step)"
