#!/usr/bin/env bash
# Brings the whole cluster up, or brings it back in line with the code: every
# Terraform stage in order, waiting between them for what the next one needs.
# Safe to re-run at any point; a stage with nothing to change is a no-op.
#
#   terraform/bootstrap     the GCS bucket every other stage keeps its state in
#   terraform/gcp           VMs, network, firewall, DNS, Secret Manager; the
#                           nodes install Docker and Dokploy, form the swarm,
#                           create Dokploy's admin and API key and put Dokploy
#                           on https://dokploy.<domain> by themselves
#   terraform/platform      the registry, OpenBao (it initializes itself), and
#                           https://bao.<domain>
#   terraform/services      OpenBao's KV mount and token role, the GitHub token
#                           in OpenBao, the CI runners
#   terraform/apps/roster   the example app, its database, Redis and secrets,
#                           and what CI deploys it with; the first image is
#                           built and deployed by CI, like every later one
#
# Needs: terraform, gh (logged in, with the repo and workflow scopes), curl,
# jq, git, and `gcloud auth application-default login` done. One-time input:
# terraform/gcp/terraform.tfvars and terraform/services/terraform.tfvars
# (see the .example files next to them).
# Usage: ./up.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for cmd in terraform gh curl jq git gcloud; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done
for f in terraform/gcp/terraform.tfvars terraform/services/terraform.tfvars; do
  [[ -f "$f" ]] || { echo "missing $f: copy $f.example and fill it in" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "gh isn't logged in: gh auth login" >&2; exit 1; }
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || { echo "no Application Default Credentials: gcloud auth application-default login" >&2; exit 1; }

log() { echo; echo "== $*"; }

tf() {
  # tf <stage> <terraform args...>
  local stage="$1"; shift
  terraform -chdir="terraform/$stage" "$@"
}

apply() {
  # apply <stage> [extra apply args...]
  local stage="$1"; shift
  log "terraform/$stage"
  tf "$stage" init -input=false >/dev/null
  tf "$stage" apply -input=false -auto-approve "$@"
}

wait_for() {
  # wait_for <description> <seconds> <command...> - polls every 10s.
  local what="$1" secs="$2" waited=0; shift 2
  echo "   waiting for $what"
  until "$@" >/dev/null 2>&1; do
    if (( waited >= secs )); then
      echo "gave up waiting for $what after $((secs / 60)) minutes" >&2
      return 1
    fi
    sleep 10; waited=$((waited + 10))
  done
}

gcp_out() { tf gcp output -raw "$1"; }

secret_value() {
  # secret_value <secret id> - its latest version, with the ADC credentials
  # Terraform uses too.
  curl -sSf -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
    "https://secretmanager.googleapis.com/v1/$1/versions/latest:access" \
    | jq -er '.payload.data | @base64d'
}

dokploy_ready() {
  # Answers over HTTPS with a valid certificate, and takes the key the
  # control plane minted.
  local key
  key="$(secret_value "$(gcp_out dokploy_api_key_secret)")" || return 1
  curl -sSf -m 10 -H @<(printf 'x-api-key: %s\n' "$key") \
    "$(gcp_out dokploy_url)/api/settings.getDokployVersion"
}

openbao_ready() {
  # 200: initialized (by itself), unsealed and active, behind a valid
  # certificate.
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$(tf platform output -raw openbao_url)/v1/sys/health")" == 200 ]]
}

runners_online() {
  local repo
  repo="$(tf services output -raw github_repo)"
  [[ "$(gh api "repos/${repo}/actions/runners" --jq '[.runners[] | select(.status == "online")] | length')" -ge 1 ]]
}

# --- stages ------------------------------------------------------------------------

log "terraform/bootstrap"
tf bootstrap init -input=false >/dev/null
tf bootstrap apply -input=false -auto-approve

apply gcp
# A fresh control plane takes about 5 minutes: Docker, Dokploy, its admin and
# key, then a Let's Encrypt certificate for its domain.
wait_for "Dokploy at $(gcp_out dokploy_url)" 1200 dokploy_ready

apply platform
wait_for "OpenBao at $(tf platform output -raw openbao_url)" 600 openbao_ready

apply services
wait_for "a CI runner to come online on GitHub" 600 runners_online

# The app's image is built by CI from main, like every later one: the tag is
# the last commit on origin/main that touched web-app/, the same one the
# workflow computes.
git fetch --quiet origin main
TAG="$(git log -1 --format=%h origin/main -- web-app)"
export GITHUB_TOKEN
GITHUB_TOKEN="$(gh auth token)"

deployed_image() {
  local key
  key="$(secret_value "$(gcp_out dokploy_api_key_secret)")"
  curl -sSf -H @<(printf 'x-api-key: %s\n' "$key") \
    "$(gcp_out dokploy_url)/api/application.one?applicationId=$(tf apps/roster output -raw app_id)" \
    | jq -r 'select(.applicationStatus == "done") | .dockerImage'
}

if tf apps/roster output -raw app_id >/dev/null 2>&1 && [[ "$(deployed_image)" == */roster:"$TAG" ]]; then
  apply apps/roster
else
  # Created without deploying: the image doesn't exist until CI builds it.
  apply apps/roster -var deploy_app=false -var "image_tag=$TAG"

  REPO="$(tf services output -raw github_repo)"
  log "building and deploying roster:$TAG with CI"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run web-app-ci.yml --repo "$REPO" --ref main
  run_id=""
  for _ in $(seq 1 30); do
    run_id="$(gh run list --repo "$REPO" --workflow web-app-ci.yml --event workflow_dispatch \
      --json databaseId,createdAt --jq "map(select(.createdAt >= \"$started\")) | first | .databaseId // empty")"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || { echo "the workflow run didn't show up on GitHub" >&2; exit 1; }
  gh run watch "$run_id" --repo "$REPO" --exit-status --interval 15 >/dev/null \
    || { echo "CI failed: gh run view $run_id --repo $REPO --log-failed" >&2; exit 1; }
  # A green run isn't proof: a workflow on main without the deploy job passes
  # too.
  [[ "$(deployed_image)" == */roster:"$TAG" ]] \
    || { echo "CI passed but the app doesn't run roster:$TAG: is the workflow with the deploy job pushed to main?" >&2; exit 1; }

  apply apps/roster
fi

log "cluster up"
cat <<EOF
   Dokploy   $(gcp_out dokploy_url)
             $(gcp_out dokploy_admin_email), password: terraform -chdir=terraform/gcp output -raw dokploy_admin_password
   OpenBao   $(tf platform output -raw openbao_url)/ui
             userpass "terraform", password: the dokploy-openbao-password secret in GCP Secret Manager
   Roster    $(tf apps/roster output -raw url)
             $(tf apps/roster output -raw admin_email), password: terraform -chdir=terraform/apps/roster output -raw admin_password
EOF
