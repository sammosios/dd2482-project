#!/usr/bin/env bash
# The remote target: servers someone has already provisioned (cloud VMs,
# bare metal, anything running Ubuntu with sshd), reached over ssh.
# Creating and destroying them isn't this chain's job: remote/00 starts
# from a running control plane host. Implements the target interface
# described in lib/common.sh. Nodes are "control-plane" and
# "worker-1".."worker-N", in the order of WORKER_HOSTS. Sourced by
# lib/common.sh.
#
# The hosts come from remote/hosts.env (gitignored, see
# remote/hosts.env.example), or REMOTE_HOSTS_FILE; environment variables of
# the same names take precedence over the file.
set -euo pipefail

TARGET_CP_SCRIPT="00-install-dokploy.sh"
TARGET_WORKERS_SCRIPT="02-join-workers.sh"

REMOTE_HOSTS_FILE="${REMOTE_HOSTS_FILE:-$TARGET_DIR/hosts.env}"

for _key in CP_HOST WORKER_HOSTS CP_SWARM_ADDR SSH_USER SSH_PORT SSH_KEY; do
  if [[ -z "${!_key:-}" && -f "$REMOTE_HOSTS_FILE" ]]; then
    printf -v "$_key" '%s' "$(env_file_value "$REMOTE_HOSTS_FILE" "$_key" || true)"
  fi
done
unset _key
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
WORKER_HOSTS="${WORKER_HOSTS:-}"
# Expanded here, since the file is parsed as data rather than sourced.
SSH_KEY="${SSH_KEY:-}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

[[ -n "${CP_HOST:-}" ]] \
  || { echo "no CP_HOST: create $REMOTE_HOSTS_FILE (see remote/hosts.env.example) or set CP_HOST" >&2; exit 1; }
# IP addresses, not names: they go into sslip.io domains and curl --resolve.
for _h in $CP_HOST $WORKER_HOSTS; do
  [[ "$_h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || { echo "CP_HOST and WORKER_HOSTS must be IPv4 addresses, got: '$_h'" >&2; exit 1; }
done
unset _h

# One connection per host, reused by every call for a minute: this chain
# runs hundreds of short commands. /tmp rather than $TMPDIR, whose long
# macOS path would push the socket past the 104-character limit. accept-new trusts a host key the first
# time it's seen (fresh servers) but still refuses one that changed.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto -o "ControlPath=/tmp/dokploy-ssh-%C" -o ControlPersist=60)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")
# sudo -n: fail rather than prompt, which would swallow piped stdin.
[[ "$SSH_USER" == root ]] && SUDO="" || SUDO="sudo -n "

target_require() { require ssh scp; }

cp_node() { echo "control-plane"; }

worker_nodes() {
  local i=0 _
  for _ in $WORKER_HOSTS; do
    i=$((i + 1))
    echo "worker-$i"
  done
}

node_ip() {
  local node="$1" hosts
  case "$node" in
    control-plane) echo "$CP_HOST" ;;
    worker-[0-9]*)
      read -r -a hosts <<<"$WORKER_HOSTS"
      local i="${node#worker-}"
      [[ "$i" -ge 1 && "$i" -le "${#hosts[@]}" ]] || return 1
      echo "${hosts[$((i - 1))]}" ;;
    *) return 1 ;;
  esac
}

node_exists() { node_ip "$1" >/dev/null; }

node_run() {
  # ssh hands the remote side one command line, which the login shell
  # re-parses, so every argument is quoted for it here.
  local node="$1" ip; shift
  ip="$(node_ip "$node")" || { echo "unknown node: $node" >&2; return 1; }
  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "${SSH_USER}@${ip}" -- "${SUDO}$(printf '%q ' "$@")"
}

node_copy() {
  local ip
  ip="$(node_ip "$2")" || { echo "unknown node: $2" >&2; return 1; }
  scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$1" "${SSH_USER}@${ip}:$3"
}

node_hint() { echo "ssh -p $SSH_PORT ${SSH_USER}@$(node_ip "$1") sudo"; }

cp_swarm_addr() {
  # CP_SWARM_ADDR if set, or the control plane's own primary IPv4 - its
  # private address on clouds that NAT public IPs (AWS, GCP, ...), which is
  # also what workers in the same network should use.
  if [[ -z "${CP_SWARM_ADDR:-}" ]]; then
    CP_SWARM_ADDR="$(node_exec control-plane ip -4 route get 1.1.1.1 \
      | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    [[ -n "$CP_SWARM_ADDR" ]] \
      || { echo "could not detect the control plane's address — set CP_SWARM_ADDR in $REMOTE_HOSTS_FILE" >&2; return 1; }
  fi
  echo "$CP_SWARM_ADDR"
}

node_wait_ready() {
  # Fresh servers may still be running cloud-init, which holds apt's lock
  # that Docker's and Dokploy's installers need. Over ssh, unlike multipass
  # exec, `cloud-init status --wait` is safe to block on.
  local node="$1"
  node_exec "$node" true >/dev/null \
    || { echo "cannot run commands on $node as ${SSH_USER} with passwordless sudo: $(node_hint "$node") true" >&2; return 1; }
  if node_exec "$node" sh -c 'command -v cloud-init' >/dev/null 2>&1; then
    echo "== waiting for cloud-init on $node"
    NODE_EXEC_TIMEOUT=900 node_exec "$node" cloud-init status --wait >/dev/null || true
  fi
  echo "== $node ($(node_ip "$node")) ready"
}
