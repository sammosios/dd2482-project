#!/usr/bin/env bash
# Deploys self-hosted GitHub Actions runners onto the cluster, one per
# worker, as the Dokploy stack stacks/github-runner.yml. See DESIGN.md for
# the why:
#   - myoung34/github-runner, which registers itself with a PAT on every
#     start, so nothing here has to mint (short-lived) registration tokens
#   - ephemeral: one job per container, then Swarm starts a clean one
#   - Swarm global mode on node.role == worker: every worker gets a runner,
#     including ones 02-launch-worker-vms.sh adds later
#   - the node's Docker socket is mounted, so jobs can build and push to the
#     cluster registry at 127.0.0.1:5000 (never localhost, see DESIGN.md)
#
# The PAT comes from GITHUB_RUNNER_PAT, or .github-runner.env (gitignored,
# see .github-runner.env.example). It reaches the runners as an external
# Swarm secret named after a hash of the token, so a new PAT rolls out a
# new secret instead of colliding with the old (immutable) one, and it never
# appears in the compose file Dokploy stores.
#
# Safe to re-run: reuses the Dokploy entries and the secret if they exist,
# and only redeploys when the compose file changed or runners are missing.
# Usage: ./04-setup-ci-runner.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh
source lib/dokploy.sh

require multipass curl jq openssl

PROJECT_NAME="infrastructure"
COMPOSE_NAME="github-runner"
RUNNER_IMAGE_TAG="${RUNNER_IMAGE_TAG:-2.337.0-ubuntu-noble}"
# Target these from workflows with `runs-on: [self-hosted, dokploy]`.
# GitHub adds self-hosted/Linux/<arch> on top.
RUNNER_LABELS="${RUNNER_LABELS:-dokploy}"
RUNNER_ENV_FILE="./.github-runner.env"

# --- inputs ------------------------------------------------------------------

if [[ -z "${GITHUB_RUNNER_PAT:-}" && -f "$RUNNER_ENV_FILE" ]]; then
  GITHUB_RUNNER_PAT="$(env_file_value "$RUNNER_ENV_FILE" GITHUB_RUNNER_PAT || true)"
fi
if [[ -z "${GITHUB_REPO:-}" && -f "$RUNNER_ENV_FILE" ]]; then
  GITHUB_REPO="$(env_file_value "$RUNNER_ENV_FILE" GITHUB_REPO || true)"
fi
if [[ -z "${GITHUB_REPO:-}" ]]; then
  # https://github.com/owner/name(.git) or git@github.com:owner/name(.git)
  GITHUB_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
fi

[[ -n "${GITHUB_RUNNER_PAT:-}" ]] \
  || { echo "no GitHub PAT: set GITHUB_RUNNER_PAT or create $RUNNER_ENV_FILE (see .github-runner.env.example)" >&2; exit 1; }
[[ "${GITHUB_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || { echo "GITHUB_REPO must be owner/name, got: '${GITHUB_REPO:-}'" >&2; exit 1; }
GITHUB_REPO_URL="https://github.com/${GITHUB_REPO}"

github_api() {
  # github_api <path> [extra curl args...] - the token goes in through a
  # file descriptor rather than argv, so it doesn't show up in `ps`.
  local path="$1"; shift
  curl -sSf -H @<(printf 'Authorization: Bearer %s\n' "$GITHUB_RUNNER_PAT") \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/${path}" "$@"
}

online_runners() {
  # Number of this cluster's runners GitHub currently sees online (idle or busy).
  github_api "repos/${GITHUB_REPO}/actions/runners?per_page=100" \
    | jq --arg l "$RUNNER_LABELS" \
      '[.runners[] | select(.status == "online" and (.labels | any(.name == $l)))] | length' \
    || echo 0
}

# Fails fast on a bad token, before anything touches the cluster. Minting a
# registration token is exactly what the runners will do, so this checks the
# PAT has the right permission, not just that it's valid. The token it
# returns expires on its own after an hour.
echo "== checking the PAT can register runners for $GITHUB_REPO"
github_api "repos/${GITHUB_REPO}/actions/runners/registration-token" -X POST >/dev/null \
  || { echo "GitHub refused to issue a runner registration token for $GITHUB_REPO — check the PAT's repo access and 'Administration: Read and write' permission" >&2; exit 1; }

# --- cluster -----------------------------------------------------------------

vm_exists "$CP_NAME" || { echo "control plane VM not found — run 00-launch-cp-vm.sh first" >&2; exit 1; }
CP_IP="$(vm_ip "$CP_NAME")"

dokploy_api "$CP_IP" "cluster.getNodes" >/dev/null \
  || { echo "cannot reach Dokploy API on $CP_IP — run 01-dokploy-api-key.sh first" >&2; exit 1; }

WORKER_COUNT="$(cp_exec docker node ls --filter role=worker --format '{{.Status}}' | grep -c '^Ready$' || true)"
[[ "$WORKER_COUNT" -gt 0 ]] \
  || { echo "no Ready workers in the swarm, and runners only run on workers — run 02-launch-worker-vms.sh first" >&2; exit 1; }

# --- PAT as a Swarm secret ---------------------------------------------------

pat_hash="$(printf '%s' "$GITHUB_RUNNER_PAT" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-12)"
GITHUB_PAT_SECRET="github-runner-pat-${pat_hash}"

if cp_exec docker secret inspect "$GITHUB_PAT_SECRET" >/dev/null 2>&1; then
  echo "== Swarm secret $GITHUB_PAT_SECRET already exists"
else
  echo "== creating Swarm secret $GITHUB_PAT_SECRET"
  # Piped over stdin, so the token isn't in any argv on the host or the VM.
  # Not cp_exec: it can't pass stdin through. Re-checks remotely, so a
  # retry after a timeout is harmless.
  GITHUB_RUNNER_PAT="$GITHUB_RUNNER_PAT" with_timeout 60 bash -c '
    printf "%s" "$GITHUB_RUNNER_PAT" | multipass exec "$1" -- sudo bash -c \
      "docker secret inspect $2 >/dev/null 2>&1 || docker secret create $2 - >/dev/null"
  ' _ "$CP_NAME" "$GITHUB_PAT_SECRET" \
    || { rc=$?; echo "creating Swarm secret $GITHUB_PAT_SECRET failed (rc=$rc, 124 = multipass exec timed out) — re-run this script" >&2; exit 1; }
fi

# --- Dokploy project + compose resource --------------------------------------

COMPOSE_FILE="$(render_template "$STACKS_DIR/github-runner.yml" \
  RUNNER_IMAGE_TAG GITHUB_REPO_URL RUNNER_LABELS GITHUB_PAT_SECRET)"
dokploy_stack_sync "$CP_IP" "$PROJECT_NAME" "$COMPOSE_NAME" \
  "Self-hosted GitHub Actions runners, one per worker" "$COMPOSE_FILE"

if [[ "$STACK_CHANGED" == 0 && "$(online_runners)" -ge "$WORKER_COUNT" ]]; then
  echo "== runners already deployed and up to date, skipping deploy"
else
  echo "== deploying runner stack"
  dokploy_stack_deploy "$CP_IP" "$STACK_COMPOSE_ID"

  # The first start pulls a ~700MB image on every worker (several minutes
  # on a laptop connection), hence the long wait. Prints task states as
  # they change, so a slow pull doesn't look like a hang.
  echo "== waiting for $WORKER_COUNT runner(s) to come online on GitHub (first pull takes a few minutes)"
  prev_tasks=""
  for _ in $(seq 1 120); do
    [[ "$(online_runners)" -ge "$WORKER_COUNT" ]] && break
    tasks="$(cp_exec docker service ps "${STACK_NAME}_runner" --filter desired-state=running \
      --format '{{.Node}}: {{.CurrentState}} {{.Error}}' 2>/dev/null \
      | sed -E 's/ [0-9]+ (seconds?|minutes?|hours?) ago//' | sort || true)"
    if [[ "$tasks" != "$prev_tasks" ]]; then
      sed 's/^/   /' <<<"$tasks"
      prev_tasks="$tasks"
    fi
    grep -qE 'Rejected|Failed' <<<"$tasks" && {
      echo "Swarm rejected a runner task, see the error above" >&2; exit 1; }
    sleep 5
  done
  online="$(online_runners)"
  [[ "$online" -ge "$WORKER_COUNT" ]] || {
    echo "only $online of $WORKER_COUNT runner(s) online after 10 minutes — check the '$COMPOSE_NAME' deployment logs in Dokploy, or:" >&2
    echo "  multipass exec $CP_NAME -- sudo docker service ps ${STACK_NAME}_runner --no-trunc" >&2
    exit 1
  }
fi

# Secrets from earlier PATs. Swarm refuses to remove one that a task still
# uses (e.g. mid-rollout), so a failure here just means the next run gets it.
for old in $(cp_exec docker secret ls --format '{{.Name}}' | grep '^github-runner-pat-' | grep -vx "$GITHUB_PAT_SECRET" || true); do
  cp_exec docker secret rm "$old" >/dev/null 2>&1 && echo "== removed old Swarm secret $old" || true
done

echo "== runner placement:"
cp_exec docker service ps --filter desired-state=running \
  --format '   {{.Name}} on {{.Node}} ({{.CurrentState}})' "${STACK_NAME}_runner"
echo "== $(online_runners) runner(s) online for $GITHUB_REPO — use 'runs-on: [self-hosted, ${RUNNER_LABELS}]' in workflows"
