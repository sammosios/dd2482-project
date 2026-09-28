#!/usr/bin/env bash
# Launches the control-plane VM and installs Dokploy on it (its installer
# runs `docker swarm init` itself, so no manual swarm bootstrap here). Gets
# the control plane to a fully running state; deliberately does NOT
# authenticate against Dokploy's API - see 01-dokploy-api-key.sh, since
# Dokploy has no headless way to create its first admin account. Worker VMs
# are launched (and joined) separately by 02-launch-worker-vms.sh, once the
# control plane is authenticated - that split is what lets scaling out the
# cluster later be a single command against an already-running control plane.
# Usage: ./00-launch-cp-vm.sh [--cpus N] [--mem SIZE] [--disk SIZE]
#   --mem/--disk set CP_MEM (default 4G) / CP_DISK (default 30G), not the
#   workers' MEM / DISK.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpus) CPUS="$2"; shift 2 ;;
    --mem) CP_MEM="$2"; shift 2 ;;
    --disk) CP_DISK="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

require multipass curl

launch_vm "$CP_NAME" "$CP_DISK" "$CP_MEM"

CP_IP="$(vm_ip "$CP_NAME")"
if dokploy_port_open "$CP_IP"; then
  echo "== Dokploy already responding on ${CP_IP}:${DOKPLOY_PORT}, skipping install"
else
  echo "== installing Dokploy on $CP_NAME ($CP_IP)"
  # Pin ADVERTISE_ADDR explicitly to the VM's actual Multipass IP so Dokploy's
  # own IP auto-detection (the source of the #4517 join-command bug) never
  # gets a chance to guess wrong. Passed inline, not via `export`, since sudo
  # resets the environment otherwise.
  multipass exec "$CP_NAME" -- sudo bash -c "curl -fsSL https://dokploy.com/install.sh | ADVERTISE_ADDR=${CP_IP} sh"

  echo "== waiting for Dokploy to come up on port ${DOKPLOY_PORT}"
  for _ in $(seq 1 60); do
    dokploy_port_open "$CP_IP" && break
    sleep 5
  done
  dokploy_port_open "$CP_IP" || { echo "Dokploy did not come up after 5 minutes" >&2; exit 1; }
fi

echo "== Dokploy is up at http://${CP_IP}:${DOKPLOY_PORT}"
echo "== next: ./01-dokploy-api-key.sh (one-time manual admin-account step)"
