#!/usr/bin/env bash
# Tears the cluster down: every stage up.sh applies, in reverse, so each is
# destroyed while what it talks to still exists (the app's GitHub secrets and
# variables, then Dokploy's and OpenBao's records, then the VMs and DNS).
# The state bucket (terraform/bootstrap) stays.
#
# If the cluster is already gone (e.g. the VMs were deleted by hand), the
# stages that talk to it can't be destroyed: --forget drops their state
# instead, after the GitHub secrets and variables are removed.
# Usage: ./down.sh [--forget]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FORGET=0
[[ "${1:-}" == "--forget" ]] && FORGET=1

tf() {
  local stage="$1"; shift
  terraform -chdir="terraform/$stage" "$@"
}

export GITHUB_TOKEN
GITHUB_TOKEN="$(gh auth token)"

for stage in apps/roster services platform; do
  echo; echo "== terraform/$stage"
  tf "$stage" init -input=false >/dev/null
  if [[ -z "$(tf "$stage" state list 2>/dev/null)" ]]; then
    echo "   nothing to destroy"
    continue
  fi
  if (( FORGET )); then
    # GitHub is still there: clean it up properly.
    if [[ "$stage" == apps/roster ]]; then
      tf "$stage" destroy -input=false -auto-approve \
        -target=github_actions_secret.ci -target=github_actions_variable.ci
    fi
    tf "$stage" state list | while read -r addr; do tf "$stage" state rm "$addr" >/dev/null; done
    echo "   forgot its state"
  else
    extra=()
    # Its ephemeral variable has to have a value, even to destroy.
    [[ "$stage" == services ]] && extra=(-var "github_runner_pat=unused")
    tf "$stage" destroy -input=false -auto-approve "${extra[@]}" \
      || { echo "destroying terraform/$stage failed; if the cluster is already gone: ./down.sh --forget" >&2; exit 1; }
  fi
done

echo; echo "== terraform/gcp"
tf gcp init -input=false >/dev/null
tf gcp destroy -input=false -auto-approve
