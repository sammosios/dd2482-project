#!/usr/bin/env bash
# Handles Dokploy's one credential-bootstrapping step. There's no documented,
# stable public API for this (see PLAN.md), so this reverse-engineers what
# Dokploy's own UI and CI integration tests do under the hood:
#   1. POST /api/auth/sign-up/email  - creates the first admin, sets a
#      session cookie (better-auth; only works before any owner exists -
#      confirmed straight from Dokploy's own upgrade-integration-test.yml)
#   2. If an owner already exists, POST /api/auth/sign-in/email instead
#   3. GET  /api/trpc/organization.all - the new admin's org id
#   4. POST /api/trpc/user.createApiKey - generate a real API key, which
#      is what every other script in this chain actually authenticates with
# This is undocumented and could break on a Dokploy update - that's an
# accepted tradeoff for not needing a browser/webdriver dependency. If it
# breaks, falls back to printing the manual instructions.
#
# Usage (through local/ or remote/, which pick the cluster):
#   <target>/01-dokploy-api-key.sh                 # auto-provision via .dokploy-admin.env,
#                                                   # or print manual-step instructions if
#                                                   # that file doesn't exist
#   <target>/01-dokploy-api-key.sh --api-key <key> # save a manually-generated key, verify it
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source lib/common.sh

API_KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

require curl jq
target_require
load_cp

dokploy_port_open \
  || { echo "Dokploy not responding at $DOKPLOY_URL — run $CLUSTER_TARGET/$TARGET_CP_SCRIPT first" >&2; exit 1; }

print_manual_instructions() {
  cat <<EOF

== manual step required (one-time, first install only) ==
1. Open $(cp_ui_hint "$DOKPLOY_PORT" /) and create the admin account.
2. Go to Settings -> Profile -> API/CLI and generate an API token.
3. Re-run: $CLUSTER_TARGET/01-dokploy-api-key.sh --api-key <token>

(Or: cp .dokploy-admin.env.example .dokploy-admin.env, fill in real values,
and re-run this script with no flags to provision automatically instead.)

EOF
}

auto_provision() {
  local admin_env="./.dokploy-admin.env"
  [[ -f "$admin_env" ]] || return 1

  # Parsed as data, not sourced - a strong random password can easily
  # contain shell-special characters ($, !, `, etc.) that `source` would
  # try to interpret instead of treating as plain text (see env_file_value
  # in lib/common.sh).
  local DOKPLOY_ADMIN_NAME DOKPLOY_ADMIN_EMAIL DOKPLOY_ADMIN_PASSWORD
  DOKPLOY_ADMIN_NAME="$(env_file_value "$admin_env" DOKPLOY_ADMIN_NAME)"
  DOKPLOY_ADMIN_EMAIL="$(env_file_value "$admin_env" DOKPLOY_ADMIN_EMAIL)"
  DOKPLOY_ADMIN_PASSWORD="$(env_file_value "$admin_env" DOKPLOY_ADMIN_PASSWORD)"

  local missing=()
  [[ -n "$DOKPLOY_ADMIN_NAME" ]]     || missing+=(DOKPLOY_ADMIN_NAME)
  [[ -n "$DOKPLOY_ADMIN_EMAIL" ]]    || missing+=(DOKPLOY_ADMIN_EMAIL)
  [[ -n "$DOKPLOY_ADMIN_PASSWORD" ]] || missing+=(DOKPLOY_ADMIN_PASSWORD)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "$admin_env is missing required value(s): ${missing[*]}" >&2
    echo "see .dokploy-admin.env.example for the expected format" >&2
    exit 1
  fi

  local base="${DOKPLOY_URL}/api"
  local cookie_jar body_file
  cookie_jar="$(mktemp)"; chmod 600 "$cookie_jar"
  body_file="$(mktemp)"
  trap 'rm -f "$cookie_jar" "$body_file"' RETURN

  echo "== provisioning admin account via /api/auth/sign-up/email"
  local code
  code="$(curl -sS -o "$body_file" -w '%{http_code}' -X POST "${base}/auth/sign-up/email" \
    -H "Content-Type: application/json" -c "$cookie_jar" -b "$cookie_jar" \
    -d "$(jq -n --arg n "$DOKPLOY_ADMIN_NAME" --arg e "$DOKPLOY_ADMIN_EMAIL" --arg p "$DOKPLOY_ADMIN_PASSWORD" \
          '{name:$n,email:$e,password:$p}')")"

  if [[ "$code" != 2* ]]; then
    echo "  sign-up returned $code (likely an owner already exists), trying sign-in instead"
    code="$(curl -sS -o "$body_file" -w '%{http_code}' -X POST "${base}/auth/sign-in/email" \
      -H "Content-Type: application/json" -c "$cookie_jar" -b "$cookie_jar" \
      -d "$(jq -n --arg e "$DOKPLOY_ADMIN_EMAIL" --arg p "$DOKPLOY_ADMIN_PASSWORD" '{email:$e,password:$p}')")"
    if [[ "$code" != 2* ]]; then
      echo "  sign-in also failed ($code): $(cat "$body_file")" >&2
      return 1
    fi
  fi

  echo "== fetching organization id"
  local org_resp org_id
  org_resp="$(curl -sSf "${base}/trpc/organization.all" -b "$cookie_jar")" || { echo "  organization.all failed: $org_resp" >&2; return 1; }
  org_id="$(echo "$org_resp" | jq -r '.result.data.json[0].id // empty')"
  [[ -n "$org_id" ]] || { echo "  could not extract organization id from: $org_resp" >&2; return 1; }

  echo "== generating API key via user.createApiKey"
  local key_resp
  # rateLimitEnabled must be explicit: better-auth's api-key plugin defaults
  # to rate limiting ON (10 requests/24h) when the field is omitted, which
  # silently breaks a key meant to drive this whole automation - found this
  # the hard way after re-running the chain a handful of times.
  key_resp="$(curl -sSf -X POST "${base}/trpc/user.createApiKey" \
    -H "Content-Type: application/json" -b "$cookie_jar" \
    -d "$(jq -n --arg org "$org_id" '{json:{name:"provisioning",metadata:{organizationId:$org},rateLimitEnabled:false}}')")" \
    || { echo "  user.createApiKey failed: $key_resp" >&2; return 1; }

  API_KEY="$(echo "$key_resp" | jq -r '.result.data.json.key // empty')"
  [[ -n "$API_KEY" ]] || { echo "  could not extract API key from: $key_resp" >&2; return 1; }

  echo "== admin account + API key provisioned automatically"
}

if [[ -z "$API_KEY" && ! -f "$API_KEY_FILE" && -z "${DOKPLOY_API_KEY:-}" ]]; then
  auto_provision || true
fi

if [[ -n "$API_KEY" ]]; then
  ( umask 077; echo "$API_KEY" >"$API_KEY_FILE" )
  echo "== saved API key to $API_KEY_FILE"
fi

if [[ -n "${DOKPLOY_API_KEY:-}" || -f "$API_KEY_FILE" ]]; then
  echo "== verifying API key against cluster.getNodes"
  if dokploy_api "cluster.getNodes" >/dev/null; then
    echo "== API key verified, ready for $CLUSTER_TARGET/$TARGET_WORKERS_SCRIPT"
  else
    echo "API key rejected by Dokploy — check it was generated correctly" >&2
    exit 1
  fi
else
  print_manual_instructions
  exit 1
fi
