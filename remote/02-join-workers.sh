#!/usr/bin/env bash
# Joins every host in WORKER_HOSTS into the control plane's Docker Swarm
# over ssh, installing Docker first where it's missing (join_worker in
# lib/common.sh). The remote counterpart of local/02-launch-worker-vms.sh:
# to scale out, provision a server, add it to WORKER_HOSTS and re-run.
#
# Before any worker joins, every node's port guard learns every node's
# address (remote/lib/prepare.sh), since Swarm's ports only answer to
# them; then each worker is checked for a usable network before it joins.
# Safe to re-run: skips workers already part of the swarm.
# Usage: remote/02-join-workers.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=remote
source lib/common.sh
source remote/lib/prepare.sh

require curl jq
target_require
load_cp
require_dokploy_api

workers="$(worker_nodes)"
if [[ -z "$workers" ]]; then
  echo "== no WORKER_HOSTS configured, the control plane will run everything"
  exit 0
fi

cp_addr="$(cp_swarm_addr)"
peers=("$cp_addr")
for node in $workers; do
  node_wait_ready "$node"
  addr="$(node_swarm_addr "$node")"
  [[ -n "$addr" ]] || { echo "could not tell which address $node reaches the control plane ($cp_addr) from" >&2; exit 1; }
  check_swarm_iface "$node" "$addr"
  peers+=("$addr")
done

for node in "$CP_NODE" $workers; do
  install_port_guard "$node" "${peers[@]}"
done

for node in $workers; do
  ensure_docker "$node"
  check_container_dns "$node"
  check_swarm_reachable "$node" "$cp_addr"
  join_worker "$node"
done

echo "== verifying cluster membership"
node_exec "$CP_NODE" docker node ls
