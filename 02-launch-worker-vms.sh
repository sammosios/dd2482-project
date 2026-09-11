#!/usr/bin/env bash
# Launches worker VMs and joins each one into the control plane's Docker
# Swarm, using the join command Dokploy itself generates (cluster.addWorker)
# rather than a manual `docker swarm init`/token dance. Launch and join are
# one pass per worker, not "launch all, then join all" - so this script
# alone is "scale the cluster by N workers" against an already-running
# control plane, matching the proposal's claim that new VMs can join and
# scale the cluster horizontally. Safe to re-run: skips VMs that already
# exist and skips the join for workers already part of the swarm.
# Usage: ./02-launch-worker-vms.sh [--workers N] [--cpus N] [--mem SIZE] [--disk SIZE]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
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

require multipass curl jq

vm_exists "$CP_NAME" || { echo "control plane VM not found — run 00-launch-cp-vm.sh first" >&2; exit 1; }
CP_IP="$(vm_ip "$CP_NAME")"

# Confirms Dokploy is reachable and the API key works before touching any worker.
dokploy_api "$CP_IP" "cluster.getNodes" >/dev/null \
  || { echo "cannot reach Dokploy API on $CP_IP — run 01-dokploy-api-key.sh first" >&2; exit 1; }

already_joined() {
  local name="$1" state
  state="$(with_timeout 15 multipass exec "$name" -- sudo docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo unknown)"
  [[ "$state" == "active" ]]
}

launch_and_join() {
  local name="$1"

  launch_vm "$name"
  ensure_docker "$name"

  if already_joined "$name"; then
    echo "== $name already part of the swarm, skipping join"
    return 0
  fi

  echo "== fetching worker join command from Dokploy (cluster.addWorker) for $name"
  local resp
  resp="$(dokploy_api "$CP_IP" "cluster.addWorker")"

  # NOTE: exact response field is unconfirmed until we hit a live instance -
  # try the likely field names, fall back to grepping the raw command out of
  # whatever comes back.
  local raw_cmd
  raw_cmd="$(echo "$resp" | jq -r '.command // .data.command // empty' 2>/dev/null || true)"
  if [[ -z "$raw_cmd" ]]; then
    raw_cmd="$(echo "$resp" | grep -o 'docker swarm join[^"]*' || true)"
  fi
  [[ -n "$raw_cmd" ]] || { echo "could not extract join command from Dokploy response: $resp" >&2; return 1; }

  local token
  token="$(echo "$raw_cmd" | grep -oE 'SWMTKN-[A-Za-z0-9.-]+')"
  [[ -n "$token" ]] || { echo "could not extract swarm token from: $raw_cmd" >&2; return 1; }

  local advertised_ip
  advertised_ip="$(echo "$raw_cmd" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}:2377' | cut -d: -f1 || true)"
  if [[ "$advertised_ip" != "$CP_IP" ]]; then
    echo "== Dokploy#4517: generated join IP ($advertised_ip) != actual control-plane IP ($CP_IP), correcting"
  fi

  # Always rebuild against the known-good Multipass IP rather than trust
  # whatever Dokploy embedded (see architecture note in PLAN.md).
  local join_cmd="docker swarm join --token ${token} ${CP_IP}:2377"

  echo "== joining $name to the swarm"
  multipass exec "$name" -- sudo bash -c "$join_cmd"
}

for i in $(seq 1 "$WORKERS"); do
  launch_and_join "$(worker_name "$i")"
done

echo "== verifying cluster membership"
multipass exec "$CP_NAME" -- sudo docker node ls
