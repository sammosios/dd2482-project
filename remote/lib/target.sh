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
CP_SWARM_ADDR="${CP_SWARM_ADDR:-}"
# Expanded here, since the file is parsed as data rather than sourced.
SSH_KEY="${SSH_KEY:-}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

[[ -n "${CP_HOST:-}" ]] \
  || { echo "no CP_HOST: create $REMOTE_HOSTS_FILE (see remote/hosts.env.example) or set CP_HOST" >&2; exit 1; }
# IP addresses, not names: they go into sslip.io domains and the nodes'
# firewall allowlists.
for _h in $CP_HOST $WORKER_HOSTS $CP_SWARM_ADDR; do
  [[ "$_h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || { echo "CP_HOST, WORKER_HOSTS and CP_SWARM_ADDR must be IPv4 addresses, got: '$_h'" >&2; exit 1; }
done
unset _h
[[ -z "$SSH_KEY" || -r "$SSH_KEY" ]] || { echo "SSH_KEY $SSH_KEY is not a readable file" >&2; exit 1; }

# $STATE_DIR holds one cluster's keys: refuse to use them against another.
if [[ -f "$STATE_DIR/cp-host" ]]; then
  [[ "$(cat "$STATE_DIR/cp-host")" == "$CP_HOST" ]] \
    || { echo "$STATE_DIR belongs to the cluster at $(cat "$STATE_DIR/cp-host"), not CP_HOST $CP_HOST — if that cluster is gone, run remote/forget.sh" >&2; exit 1; }
else
  echo "$CP_HOST" >"$STATE_DIR/cp-host"
fi

# accept-new trusts a host key the first time it's seen (fresh servers) but
# still refuses one that changed. The keepalives turn a dead connection into
# an error within a minute instead of a hang. LogLevel keeps ssh's own
# notices ("Permanently added ...") out of command output.
SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR -p "$SSH_PORT")
[[ -n "$SSH_KEY" ]] && SSH_BASE_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
# One connection per host, reused by every call for a minute: this chain
# runs hundreds of short commands. /tmp rather than $TMPDIR, whose long
# macOS path would push the socket past the 104-character limit.
SSH_OPTS=("${SSH_BASE_OPTS[@]}" -o ControlMaster=auto -o "ControlPath=/tmp/dokploy-ssh-%C" -o ControlPersist=60)
# sudo -n: fail rather than prompt, which would swallow piped stdin.
[[ "$SSH_USER" == root ]] && SUDO="" || SUDO="sudo -n "

target_require() { require ssh; }

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

sh_quote() {
  # Quotes each argument for a POSIX shell: in single quotes, with each '
  # written as '\''. Unlike printf %q, whatever the login shell is (bash,
  # dash, zsh) reads it back unchanged.
  local a out="" q="'" r="'\\''"
  for a in "$@"; do out+="'${a//$q/$r}' "; done
  printf '%s' "$out"
}

node_run() {
  # ssh hands the remote side one command line, which the login shell
  # re-parses, so every argument is quoted for it here.
  local node="$1" ip; shift
  ip="$(node_ip "$node")" || { echo "unknown node: $node" >&2; return 1; }
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" -- "${SUDO}$(sh_quote "$@")"
}

node_copy() {
  # Over the ssh connection itself rather than scp, which not every server
  # has an sftp subsystem for.
  local ip
  ip="$(node_ip "$2")" || { echo "unknown node: $2" >&2; return 1; }
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" -- "cat > $(sh_quote "$3")" <"$1"
}

node_hint() { echo "ssh -p $SSH_PORT ${SSH_USER}@$(node_ip "$1") sudo"; }

cp_swarm_addr() {
  # CP_SWARM_ADDR if set, or the control plane's own primary IPv4 - its
  # private address on clouds that NAT public IPs (AWS, GCP, ...), which is
  # also what workers in the same network should use.
  local addr="$CP_SWARM_ADDR"
  if [[ -z "$addr" ]]; then
    addr="$(node_exec control-plane ip -4 route get 1.1.1.1 \
      | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    [[ -n "$addr" ]] \
      || { echo "could not detect the control plane's address — set CP_SWARM_ADDR in $REMOTE_HOSTS_FILE" >&2; return 1; }
  fi
  echo "$addr"
}

cp_connect() {
  # Dokploy, the registry and OpenBao speak plain HTTP and are closed to the
  # network (remote/node/dokploy-port-guard), so reach them through an ssh
  # tunnel to the control plane's loopback instead, on free local ports.
  # The tunnel is its own ssh process, closed when the script exits.
  local sock="/tmp/dokploy-tun-$$" base err
  err="$(mktemp)"
  for _ in 1 2 3 4 5; do
    base=$((20000 + RANDOM % 30000))
    if ssh "${SSH_BASE_OPTS[@]}" -M -S "$sock" -f -N -o ExitOnForwardFailure=yes \
        -L "127.0.0.1:${base}:127.0.0.1:${DOKPLOY_PORT}" \
        -L "127.0.0.1:$((base + 1)):127.0.0.1:${REGISTRY_PORT}" \
        -L "127.0.0.1:$((base + 2)):127.0.0.1:${OPENBAO_PORT}" \
        "${SSH_USER}@${CP_HOST}" </dev/null 2>"$err"; then
      rm -f "$err"
      on_exit "ssh -S '$sock' -O exit '${SSH_USER}@${CP_HOST}' >/dev/null 2>&1"
      DOKPLOY_URL="http://127.0.0.1:${base}"
      REGISTRY_URL="http://127.0.0.1:$((base + 1))"
      OPENBAO_URL="http://127.0.0.1:$((base + 2))"
      return 0
    fi
    # A taken local port is worth another try; anything else isn't.
    grep -qi 'forward' "$err" || break
  done
  echo "could not open an ssh tunnel to the control plane ($CP_HOST): $(cat "$err")" >&2
  rm -f "$err"
  exit 1
}

cp_ui_hint() {
  # cp_ui_hint <port> <path>
  echo "http://localhost:$1$2 while this runs: ssh -N -L $1:127.0.0.1:$1 -p $SSH_PORT ${SSH_USER}@${CP_HOST}"
}

node_wait_ready() {
  # Waits until the node answers ssh (a server that was just created may
  # still be booting), checks passwordless sudo, then waits for cloud-init:
  # it holds apt's lock, which Docker's and Dokploy's installers need. Over
  # ssh, unlike multipass exec, `cloud-init status --wait` is safe to block
  # on.
  local node="$1" ip out rc attempt
  ip="$(node_ip "$node")"
  for attempt in $(seq 1 30); do
    rc=0
    out="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" -- true 2>&1 </dev/null)" || rc=$?
    [[ "$rc" -eq 0 ]] && break
    case "$out" in
      *"Permission denied"*|*"Host key verification failed"*|*"IDENTIFICATION HAS CHANGED"*|*"Too many authentication failures"*)
        echo "cannot log in to $node ($ip) as $SSH_USER: $out" >&2
        [[ "$out" == *"verification failed"* || "$out" == *IDENTIFICATION* ]] \
          && echo "if the server was reinstalled: ssh-keygen -R $ip" >&2
        return 1 ;;
    esac
    if [[ "$attempt" -eq 30 ]]; then
      echo "$node ($ip) did not answer ssh on port $SSH_PORT for 10 minutes: $out" >&2
      return 1
    fi
    echo "  ($node: ssh not answering yet, retry $attempt/30)" >&2
    sleep 10
  done

  node_exec "$node" true >/dev/null \
    || { echo "cannot run commands on $node as ${SSH_USER} with passwordless sudo: $(node_hint "$node") true" >&2; return 1; }

  local os
  os="$(node_exec "$node" sh -c '. /etc/os-release && echo "$ID $VERSION_ID"' || true)"
  [[ "$os" == "ubuntu 24.04" ]] \
    || echo "  warning: $node runs '${os:-unknown}'; this chain is tested on Ubuntu 24.04" >&2

  if node_exec "$node" sh -c 'command -v cloud-init' >/dev/null 2>&1; then
    echo "== waiting for cloud-init on $node"
    # Exit code 2 means done with warnings, which is fine here.
    NODE_EXEC_TIMEOUT=900 node_exec "$node" cloud-init status --wait >/dev/null || true
  fi
  echo "== $node ($ip) ready"
}
