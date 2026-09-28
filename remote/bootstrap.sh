#!/usr/bin/env bash
# Entrypoint chaining the full script chain against servers that are
# already provisioned (for a local multipass cluster: local/bootstrap.sh).
# Which servers, and how to reach them, comes from remote/hosts.env (see
# remote/hosts.env.example): unlike the local chain, this never creates or
# sizes machines.
#
# As with the local chain, this is one command only when .dokploy-admin.env
# is set up - otherwise it stops after 01 with next-step instructions.
# Usage: remote/bootstrap.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CLUSTER_TARGET=remote
source lib/common.sh

[[ $# -eq 0 ]] || { echo "remote/bootstrap.sh takes no arguments: the hosts come from $REMOTE_HOSTS_FILE" >&2; exit 1; }

echo "== setting up control plane $CP_HOST + $(worker_nodes | wc -l | tr -d ' ') worker(s)"

remote/00-install-dokploy.sh

if ! remote/01-dokploy-api-key.sh; then
  echo
  echo "== stopped: credential bootstrap needs one more step (see instructions above)"
  echo "==   once you have a token: remote/01-dokploy-api-key.sh --api-key <token>, then re-run: remote/bootstrap.sh"
  echo "==   or set up .dokploy-admin.env (see .dokploy-admin.env.example) to skip this step entirely next time"
  exit 1
fi

remote/02-join-workers.sh
remote/03-setup-registry.sh

# Runners need a GitHub PAT, which not everyone bringing up a cluster has -
# skip them rather than fail the whole chain.
if [[ -n "${GITHUB_RUNNER_PAT:-}" || -f .github-runner.env ]]; then
  remote/04-setup-ci-runner.sh
else
  echo "== skipping CI runners: no GITHUB_RUNNER_PAT or .github-runner.env (see .github-runner.env.example)"
fi

remote/05-setup-openbao.sh
remote/06-deploy-core-services.sh
remote/07-deploy-web-app.sh

echo "== cluster up: $(( $(worker_nodes | wc -l) + 1 )) nodes, with the Roster web app deployed"
