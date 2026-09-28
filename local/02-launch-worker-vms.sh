#!/usr/bin/env bash
# Launches worker VMs and joins each one into the control plane's Docker
# Swarm (join_worker in lib/common.sh). Launch and join are one pass per
# worker, not "launch all, then join all" - so this script alone is "scale
# the cluster by N workers" against an already-running control plane,
# matching the proposal's claim that new VMs can join and scale the cluster
# horizontally. Safe to re-run: skips VMs that already exist and skips the
# join for workers already part of the swarm.
# Usage: local/02-launch-worker-vms.sh [--workers N] [--cpus N] [--mem SIZE] [--disk SIZE]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=local
source lib/common.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) WORKERS="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --mem) MEM="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

require curl jq
target_require
load_cp
require_dokploy_api

for i in $(seq 1 "$WORKERS"); do
  name="$(worker_name "$i")"
  launch_vm "$name"
  ensure_docker "$name"
  check_container_dns "$name"
  join_worker "$name"
done

echo "== verifying cluster membership"
node_run "$CP_NODE" docker node ls
