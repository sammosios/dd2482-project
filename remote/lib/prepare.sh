#!/usr/bin/env bash
# Getting a server ready to be a node, beyond Docker: its Swarm address,
# the checks that catch a network Swarm can't work over, and the port guard
# (remote/node/dokploy-port-guard). Used by remote/00 and remote/02; the
# local target needs none of it, since its VMs share a network private to
# this machine. Sourced after lib/common.sh.
set -euo pipefail

node_swarm_addr() {
  # node_swarm_addr <node> - the address the node talks to the rest of the
  # swarm from: for a worker, its source address towards the control plane.
  local node="$1" cp_addr
  cp_addr="$(cp_swarm_addr)"
  if [[ "$node" == "$(cp_node)" ]]; then
    echo "$cp_addr"
    return
  fi
  node_exec "$node" ip -4 route get "$cp_addr" \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

check_swarm_iface() {
  # check_swarm_iface <node> <addr> - the address must be the node's own,
  # and on an interface with a full-size MTU: Swarm's overlay networks don't
  # adapt theirs (1450, which needs 1500 underneath), so on smaller ones big
  # packets between nodes vanish - image pushes and database replies hang
  # while everything small works.
  local node="$1" addr="$2" iface mtu
  iface="$(node_exec "$node" ip -4 -o addr show | awk -v a="$addr" '{split($4, p, "/"); if (p[1] == a) {print $2; exit}}')"
  [[ -n "$iface" ]] || {
    echo "$addr is not an address of $node — set CP_SWARM_ADDR in $REMOTE_HOSTS_FILE to an address the control plane has on one of its interfaces" >&2
    return 1
  }
  mtu="$(node_exec "$node" cat "/sys/class/net/${iface}/mtu")"
  if [[ "$mtu" -lt 1500 ]]; then
    echo "$node's swarm address $addr is on $iface with MTU $mtu, but Swarm's overlay networks need 1500 underneath." >&2
    echo "Use addresses on a network with MTU 1500 (for most providers the public one: leave CP_SWARM_ADDR unset)." >&2
    return 1
  fi
}

install_port_guard() {
  # install_port_guard <node> <peer addr...> - installs and (re)applies the
  # port guard, with the peers added to the node's allowlist for Swarm's
  # ports. Adds, never removes: a re-run with fewer nodes known can't cut
  # the swarm apart.
  local node="$1"; shift
  echo "== applying the port guard on $node (swarm peers: $*)"
  node_run "$node" sh -c 'cat >/usr/local/sbin/dokploy-port-guard && chmod 755 /usr/local/sbin/dokploy-port-guard' \
    <"$TARGET_DIR/node/dokploy-port-guard"
  node_run "$node" sh -c 'cat >/etc/systemd/system/dokploy-port-guard.service' \
    <"$TARGET_DIR/node/dokploy-port-guard.service"
  node_exec "$node" sh -c '
    mkdir -p /etc/dokploy-port-guard
    f=/etc/dokploy-port-guard/peers
    { cat "$f" 2>/dev/null || true; printf "%s\n" "$@"; } | sort -u >"$f.new"
    mv "$f.new" "$f"
    systemctl daemon-reload
    systemctl enable --quiet dokploy-port-guard.service
    systemctl restart dokploy-port-guard.service' _ "$@"
}

check_swarm_reachable() {
  # check_swarm_reachable <node> <cp addr> - Swarm's TCP ports on the
  # control plane, from the node. Without this, a firewall in between makes
  # `docker swarm join` hang, then leave the node half-joined.
  local node="$1" cp_addr="$2" port
  for port in 2377 7946; do
    # exit 1 rather than timeout's 124, which node_exec would retry.
    node_exec "$node" bash -c 'timeout 5 bash -c "</dev/tcp/$0/$1" 2>/dev/null || exit 1' "$cp_addr" "$port" || {
      echo "$node can't reach the control plane on ${cp_addr}:${port}/tcp — open 2377/tcp, 7946/tcp+udp and 4789/udp between the nodes in the provider's firewall" >&2
      return 1
    }
  done
}
