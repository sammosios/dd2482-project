#!/usr/bin/env bash
# The local target: a cluster of multipass VMs on this machine, for spinning
# up and testing. Implements the target interface described in
# lib/common.sh, plus the VM sizing and launch helpers local/00 and local/02
# use. Nodes are VM names. Sourced by lib/common.sh.
set -euo pipefail

TARGET_CP_SCRIPT="00-launch-cp-vm.sh"
TARGET_WORKERS_SCRIPT="02-launch-worker-vms.sh"

PREFIX="dokploy"
CP_NAME="${PREFIX}-control-plane"
WORKER_PREFIX="${PREFIX}-worker"

WORKERS="${WORKERS:-2}"
CPUS="${CPUS:-2}"
MEM="${MEM:-2G}"
# Workers run the CI jobs: the runner image, Trivy's database, the build
# cache and one job's files need about 9G at peak, and 15G leaves room for
# an image upgrade (see DESIGN.md "CI runners"). Sparse, like CP_DISK.
DISK="${DISK:-15G}"
# The control plane needs more than workers: Dokploy builds every image on
# the manager and the registry's volume lives there too (see DESIGN.md).
# Multipass disks are sparse, so this only costs host space as it fills.
CP_DISK="${CP_DISK:-30G}"
# Dokploy, its Postgres and Redis, Traefik, the registry and every image
# build all run on the manager, which is too much for a worker's 2G.
CP_MEM="${CP_MEM:-4G}"
IMAGE="${IMAGE:-24.04}"

# forward.sh (a gitignored, WSL-only helper in this folder) forwards these
# local ports to the control plane: Dokploy's UI, and Traefik for every
# app's *.localhost domain. Here rather than in forward.sh so 07 can print
# the app's URL. Not 8080 for the latter: that's the web app's own port when
# run locally.
FORWARD_DOKPLOY_PORT="${FORWARD_DOKPLOY_PORT:-3000}"
FORWARD_HTTP_PORT="${FORWARD_HTTP_PORT:-8081}"
# PIDs of forward.sh's socat processes, one per line. Defined here rather
# than in forward.sh so teardown.sh can stop them without it.
FORWARD_PID_FILE="$STATE_DIR/forward.pid"

# State used to live in the repo root, before there was more than one
# target: move a local cluster's files into $STATE_DIR once.
for _f in dokploy-api-key registry-credentials openbao-init.json openbao-init.json.stale web-app-credentials forward.pid; do
  if [[ -f "$ROOT_DIR/.$_f" && ! -e "$STATE_DIR/$_f" ]]; then
    mv "$ROOT_DIR/.$_f" "$STATE_DIR/$_f"
    echo "== moved .$_f to .state/local/$_f" >&2
  fi
done
unset _f

target_require() { require multipass; }

cp_node() { echo "$CP_NAME"; }

worker_name() { echo "${WORKER_PREFIX}-$1"; }

worker_nodes() {
  multipass list --format csv | awk -F, -v p="${WORKER_PREFIX}-" 'NR>1 && index($1, p) == 1 {print $1}' \
    | sort -t- -k3 -n
}

node_exists() { multipass info "$1" >/dev/null 2>&1; }

node_ip() {
  # first IPv4 line multipass reports for the instance
  multipass info "$1" --format csv 2>/dev/null | tail -n1 | cut -d',' -f3
}

# Multipass VMs share one network with each other and this machine.
cp_swarm_addr() { node_ip "$CP_NAME"; }

node_run() {
  local node="$1"; shift
  multipass exec "$node" -- sudo "$@"
}

node_copy() {
  # The multipass snap can only read non-hidden files under $HOME, so
  # callers create <file> there.
  multipass transfer "$1" "$2:$3"
}

node_hint() { echo "multipass exec $1 -- sudo"; }

node_wait_ready() {
  # `cloud-init status --wait` over `multipass exec` has been observed to hang
  # indefinitely (transport-level, not cloud-init itself - plain `cloud-init
  # status` returns instantly even while `--wait` is stuck). Poll the
  # non-blocking form instead, each call capped with `timeout` so one flaky
  # exec can't block the whole chain.
  local name="$1" attempt out
  for attempt in $(seq 1 40); do
    if out="$(with_timeout 15 multipass exec "$name" -- cloud-init status)"; then
      [[ "$out" == *"status: done"* ]] && return 0
    fi
    echo "  ($name cloud-init: ${out:-exec not ready yet}, retry $attempt/40)" >&2
    sleep 5
  done
  echo "gave up waiting for cloud-init on $name" >&2
  return 1
}

launch_vm() {
  # Shared by the control-plane and worker launch scripts: launch (unless it
  # already exists) and block until cloud-init is done.
  # launch_vm <name> [disk] [mem] - default to the workers' $DISK / $MEM.
  local name="$1" disk="${2:-$DISK}" mem="${3:-$MEM}"
  if node_exists "$name"; then
    echo "== $name already exists, skipping launch"
  else
    echo "== launching $name (cpus=$CPUS mem=$mem disk=$disk image=$IMAGE)"
    multipass launch "$IMAGE" --name "$name" --cpus "$CPUS" --memory "$mem" --disk "$disk"
  fi
  echo "== waiting for cloud-init on $name"
  node_wait_ready "$name"
  echo "== $name ready at $(node_ip "$name")"
}

host_cpus() {
  nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 0
}

host_mem_gb() {
  if command -v free >/dev/null 2>&1; then
    free -g | awk '/^Mem:/{print $2}'
  else
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    echo $(( bytes / 1024 / 1024 / 1024 ))
  fi
}

suggest_max_workers() {
  # Rough advisory estimate only - real headroom depends on what else is
  # running on the host. Reserves 2 cores / 2GB for the host OS on top of
  # what the (already-running) control plane itself needs, then divides
  # what's left by one worker's CPU/mem footprint.
  local cpus mem_gb cpu_per_vm="$CPUS" mem_per_vm="${MEM%[Gg]}" cp_mem="${CP_MEM%[Gg]}"
  cpus="$(host_cpus)"
  mem_gb="$(host_mem_gb)"
  [[ "$cpus" -gt 0 && "$mem_gb" -gt 0 ]] || { echo "?"; return; }

  local usable_cpus=$(( cpus - 2 - cpu_per_vm ))
  local usable_mem=$(( mem_gb - 2 - cp_mem ))
  local by_cpu=$(( cpu_per_vm > 0 ? usable_cpus / cpu_per_vm : 0 ))
  local by_mem=$(( mem_per_vm > 0 ? usable_mem / mem_per_vm : 0 ))
  local max=$(( by_cpu < by_mem ? by_cpu : by_mem ))
  (( max < 0 )) && max=0
  echo "$max"
}

remove_local_state() {
  # Everything in $STATE_DIR but forward.sh's PID file, which stop_forwarder
  # handles.
  local f
  for f in "$STATE_DIR"/*; do
    [[ -e "$f" && "$f" != "$FORWARD_PID_FILE" ]] || continue
    rm -f "$f"
    echo "== removed ${f#"$ROOT_DIR"/}"
  done
}

stop_forwarder() {
  # No-op unless forward.sh has started forwarders. Only kills a PID if it's
  # still socat, so a stale file can't take out an unrelated process that
  # has since reused the PID.
  [[ -f "$FORWARD_PID_FILE" ]] || return 0
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    if [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == socat ]]; then
      kill "$pid"
      echo "== stopped localhost forwarder (pid $pid)"
    fi
  done <"$FORWARD_PID_FILE"
  rm -f "$FORWARD_PID_FILE"
}
