#!/usr/bin/env bash
# Prints the cluster's logins: URL, user and password for Dokploy, OpenBao
# and Roster, read from Terraform's outputs and Secret Manager (nothing is
# stored locally). With a name, prints only that password, for piping:
#   ./creds.sh                 all logins
#   ./creds.sh dokploy | pbcopy
#   ./creds.sh openbao | pbcopy
#   ./creds.sh roster  | pbcopy
# Needs terraform, curl, jq, and `gcloud auth application-default login`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

out() {
  # out <stage> <output> - empty if the stage hasn't been applied.
  terraform -chdir="terraform/$1" output -json 2>/dev/null | jq -j --arg k "$2" '.[$k].value // empty' || true
}

secret() {
  # secret <secret id> - its latest version, with the ADC credentials.
  curl -sSf -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
    "https://secretmanager.googleapis.com/v1/$1/versions/latest:access" \
    | jq -ej '.payload.data | @base64d'
}

dokploy_password() { out gcp dokploy_admin_password; }
openbao_password() { secret "$(out gcp openbao_password_secret)"; }
roster_password() { out apps/roster admin_password; }

case "${1:-}" in
  dokploy) dokploy_password; exit ;;
  openbao) openbao_password; exit ;;
  roster) roster_password; exit ;;
  "") ;;
  *) echo "usage: $0 [dokploy|openbao|roster]" >&2; exit 1 ;;
esac

[[ -n "$(out gcp dokploy_url)" ]] || { echo "no cluster: terraform/gcp has no outputs (run ./up.sh)" >&2; exit 1; }

cat <<EOF
Dokploy   $(out gcp dokploy_url)
  user      $(out gcp dokploy_admin_email)
  password  $(dokploy_password)

OpenBao   $(out platform openbao_url)/ui  (method: Userpass)
  user      terraform
  password  $(openbao_password)
EOF

if [[ -n "$(out apps/roster url)" ]]; then
  cat <<EOF

Roster    $(out apps/roster url)
  user      $(out apps/roster admin_email)
  password  $(roster_password)
EOF
fi
