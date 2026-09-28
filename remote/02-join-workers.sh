#!/usr/bin/env bash
# Joins every host in WORKER_HOSTS into the control plane's Docker Swarm
# over ssh, installing Docker first where it's missing (join_worker in
# lib/common.sh). The remote counterpart of local/02-launch-worker-vms.sh:
# to scale out, provision a server, add it to WORKER_HOSTS and re-run.
# Safe to re-run: skips workers already part of the swarm.
# Usage: remote/02-join-workers.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=remote
source lib/common.sh

require curl jq
target_require
load_cp
require_dokploy_api

workers="$(worker_nodes)"
[[ -n "$workers" ]] || echo "== no WORKER_HOSTS configured, the control plane will run everything"

for node in $workers; do
  node_wait_ready "$node"
  ensure_docker "$node"
  join_worker "$node"
done

echo "== verifying cluster membership"
node_run "$CP_NODE" docker node ls
