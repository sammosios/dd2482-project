#!/usr/bin/env bash
# OpenBao helpers shared by 05-setup-openbao.sh and APP-PROJECT-SETUP.md. Talks to
# OpenBao's HTTP API from this machine (at OPENBAO_URL, see cp_connect in
# lib/common.sh), with plain curl and jq, so it needs no bao CLI. Sourced
# after lib/common.sh; expects load_cp to have run.
set -euo pipefail

# The KV v2 mount Dokploy's providers read from. "secret" is Dokploy's
# default, so providers don't need to set it.
OPENBAO_KV_MOUNT="secret"
# Token role every Dokploy provider token is issued from (see 05).
OPENBAO_PROVIDER_ROLE="dokploy-provider"
# Per-project policies are named ${OPENBAO_POLICY_PREFIX}<project>; the
# provider role may only hand out policies matching this prefix.
OPENBAO_POLICY_PREFIX="dokploy-project-"
# Address Dokploy's server uses, over dokploy-network (the alias in
# stacks/openbao.yml).
OPENBAO_INTERNAL_URL="http://openbao:8200"

bao_status() {
  # HTTP status of /v1/sys/health: 200 unsealed and active, 501 not
  # initialized, 503 sealed, 000 nothing listening yet.
  curl -s -o /dev/null -m 5 -w '%{http_code}' "${OPENBAO_URL}/v1/sys/health" || true
}

bao_root_token() {
  [[ -f "$OPENBAO_INIT_FILE" ]] \
    || { echo "no $OPENBAO_INIT_FILE — run 05-setup-openbao.sh first" >&2; return 1; }
  jq -er '.root_token' "$OPENBAO_INIT_FILE"
}

bao_api() {
  # bao_api <path> [extra curl args...] - authenticated with the root token,
  # which goes in through a file descriptor rather than argv, so it doesn't
  # show up in `ps`.
  local path="$1" token; shift
  token="$(bao_root_token)"
  curl -sSf -H @<(printf 'X-Vault-Token: %s\n' "$token") \
    "${OPENBAO_URL}/v1/${path}" "$@"
}
