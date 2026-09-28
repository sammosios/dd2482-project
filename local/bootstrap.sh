#!/usr/bin/env bash
# Entrypoint chaining the full script chain against a local multipass
# cluster (for a remote one: remote/bootstrap.sh). Worker count is mandatory -
# pass it (as a bare number or --workers N) or you'll be prompted for it,
# with a rough estimate of how many this device could handle.
#
# This is genuinely one command ONLY when .dokploy-admin.env is set up
# (see .dokploy-admin.env.example) - 01-dokploy-api-key.sh still has a real
# manual step otherwise (Dokploy has no headless way to create its first
# admin account without it), and this script stops cleanly with next-step
# instructions rather than pretending to have finished. See PLAN.md's
# "Credential bootstrap" section.
#
# Usage:
#   local/bootstrap.sh 3                                  # 3 workers
#   local/bootstrap.sh --workers 3 [--cpus N] [--mem SIZE] [--disk SIZE]
#                      [--cp-mem SIZE] [--cp-disk SIZE]   # --mem/--disk are per worker
#   local/bootstrap.sh                                    # prompts for worker count
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=local
source lib/common.sh

WORKERS_SET=0
if [[ $# -gt 0 && "$1" != --* ]]; then
  WORKERS="$1"; WORKERS_SET=1; shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) WORKERS="$2"; WORKERS_SET=1; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --mem) MEM="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --cp-mem) CP_MEM="$2"; shift 2 ;;
    --cp-disk) CP_DISK="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ "$WORKERS_SET" -eq 0 ]]; then
  cpus_detected="$(host_cpus)"
  mem_detected="$(host_mem_gb)"
  cp_mem="${CP_MEM%[Gg]}"

  if [[ "$cpus_detected" -gt 0 && "$mem_detected" -gt 0 ]]; then
    suggestion="$(suggest_max_workers)"
    echo "== host: ${cpus_detected} CPU cores / ${mem_detected}GB RAM detected"
    echo "== estimate: this device could handle roughly ${suggestion} worker VM(s)"
    echo "==   (reserves ~2 cores/2GB for the host OS beyond the control plane's own ${CPUS} cores/${cp_mem}GB;"
    echo "==   actual headroom depends on what else is running)"
  else
    echo "== could not auto-detect host CPU/RAM on this platform"
  fi
  read -r -p "How many workers? " WORKERS
fi

[[ "$WORKERS" =~ ^[0-9]+$ ]] || { echo "workers must be a non-negative integer, got: '$WORKERS'" >&2; exit 1; }

echo "== spinning up control plane + $WORKERS worker(s)"

local/00-launch-cp-vm.sh --cpus "$CPUS" --mem "$CP_MEM" --disk "$CP_DISK"

# forward.sh is a gitignored, WSL-only local helper (see the script itself)
# - run it if present, so Dokploy and the apps are reachable from Windows,
# Dokploy already before 01 needs the browser. Not fatal: the cluster
# itself is fine without it.
if [[ -x local/forward.sh ]]; then
  local/forward.sh || echo "== warning: local/forward.sh failed, Dokploy and the apps are not forwarded to localhost" >&2
fi

if ! local/01-dokploy-api-key.sh; then
  echo
  echo "== stopped: credential bootstrap needs one more step (see instructions above)"
  echo "==   once you have a token: local/01-dokploy-api-key.sh --api-key <token>, then re-run: local/bootstrap.sh $WORKERS"
  echo "==   or set up .dokploy-admin.env (see .dokploy-admin.env.example) to skip this step entirely next time"
  exit 1
fi

local/02-launch-worker-vms.sh --workers "$WORKERS" --cpus "$CPUS" --mem "$MEM" --disk "$DISK"
local/03-setup-registry.sh

# Runners need a GitHub PAT, which not everyone bringing up a cluster has -
# skip them rather than fail the whole chain.
if [[ -n "${GITHUB_RUNNER_PAT:-}" || -f .github-runner.env ]]; then
  local/04-setup-ci-runner.sh
else
  echo "== skipping CI runners: no GITHUB_RUNNER_PAT or .github-runner.env (see .github-runner.env.example)"
fi

local/05-setup-openbao.sh
local/06-deploy-core-services.sh
local/07-deploy-web-app.sh

echo "== cluster up: $((WORKERS + 1)) nodes, with the Roster web app deployed"
