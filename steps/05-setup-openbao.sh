#!/usr/bin/env bash
# Deploys OpenBao, the cluster's secrets manager for app projects, as the
# Dokploy stack stacks/openbao.yml, then initializes and configures it so
# each app project can get its own Dokploy secrets provider (APP-PROJECT-SETUP.md).
# See DESIGN.md "Secrets: OpenBao" for the why:
#   - single node, Raft storage on a node-local volume, pinned to the
#     manager, like the registry
#   - static-key auto-unseal: a 32-byte key generated on the control plane
#     straight into a Swarm secret, so a restarted task unseals itself and
#     the key never leaves the node
#   - joined to dokploy-network as `openbao`, because Dokploy's own server
#     fetches secrets from it at deploy time (${{vault.<provider>.<ref>}})
#   - also published on the routing mesh at :8200, for these scripts and
#     the web UI
#
# Initialization writes the root token and recovery key to the target's
# state (.state/<target>/openbao-init.json). Then it makes
# sure there is a KV v2 mount at secret/ and the token role that
# app project provider tokens are issued from (APP-PROJECT-SETUP.md).
#
# Safe to re-run: reuses the Swarm secret, config and Dokploy entries,
# initializes only once, and only redeploys when the compose file changed or
# OpenBao is down.
# Usage: <target>/05-setup-openbao.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source lib/common.sh
source lib/dokploy.sh
source lib/openbao.sh

require curl jq openssl base64
target_require

PROJECT_NAME="infrastructure"
COMPOSE_NAME="openbao"
OPENBAO_IMAGE_TAG="${OPENBAO_IMAGE_TAG:-2.7.0}"
# Never change these on a running cluster: the stored data is sealed with
# this exact key. Rotation needs previous_key in stacks/openbao.hcl.
OPENBAO_UNSEAL_KEY_ID="cluster-1"
OPENBAO_UNSEAL_SECRET="openbao-unseal-key-${OPENBAO_UNSEAL_KEY_ID}"

load_cp
require_dokploy_api

# --- unseal key as a Swarm secret --------------------------------------------

# Generated on the control plane itself and piped straight into the secret,
# so it never exists on this machine or in any file. Re-checks remotely, so a
# retry after a timeout is harmless.
if cp_exec docker secret inspect "$OPENBAO_UNSEAL_SECRET" >/dev/null 2>&1; then
  echo "== Swarm secret $OPENBAO_UNSEAL_SECRET already exists"
else
  echo "== generating unseal key into Swarm secret $OPENBAO_UNSEAL_SECRET"
  cp_exec bash -c "docker secret inspect '${OPENBAO_UNSEAL_SECRET}' >/dev/null 2>&1 \
    || openssl rand 32 | docker secret create '${OPENBAO_UNSEAL_SECRET}' - >/dev/null"
fi

# --- server config as a Swarm config -----------------------------------------

CONFIG_HCL="$(render_template "$STACKS_DIR/openbao.hcl" OPENBAO_UNSEAL_KEY_ID)"
config_hash="$(printf '%s' "$CONFIG_HCL" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-12)"
OPENBAO_CONFIG="openbao-config-${config_hash}"

if cp_exec docker config inspect "$OPENBAO_CONFIG" >/dev/null 2>&1; then
  echo "== Swarm config $OPENBAO_CONFIG already exists"
else
  echo "== creating Swarm config $OPENBAO_CONFIG"
  # Nothing secret in it, so base64 through argv is fine (cp_exec has no stdin).
  cp_exec bash -c "docker config inspect '${OPENBAO_CONFIG}' >/dev/null 2>&1 \
    || echo '$(printf '%s' "$CONFIG_HCL" | base64 | tr -d '\n')' | base64 -d | docker config create '${OPENBAO_CONFIG}' - >/dev/null"
fi

# --- Dokploy project + compose resource --------------------------------------

COMPOSE_FILE="$(render_template "$STACKS_DIR/openbao.yml" \
  OPENBAO_IMAGE_TAG OPENBAO_PORT OPENBAO_CONFIG OPENBAO_UNSEAL_SECRET)"
dokploy_stack_sync "$PROJECT_NAME" "$COMPOSE_NAME" \
  "OpenBao secrets manager, pinned to the manager node" "$COMPOSE_FILE"

if [[ "$STACK_CHANGED" == 0 && "$(bao_status)" != 000 ]]; then
  echo "== OpenBao already deployed and up to date, skipping deploy"
else
  echo "== deploying OpenBao stack"
  dokploy_stack_deploy "$STACK_COMPOSE_ID"
  # A redeploy replaces the task, so give the old one a moment to go away
  # before trusting a status from it.
  [[ "$STACK_CHANGED" == 1 ]] && sleep 10
fi

echo "== waiting for OpenBao at $OPENBAO_URL"
for _ in $(seq 1 36); do
  [[ "$(bao_status)" != 000 ]] && break
  sleep 5
done
[[ "$(bao_status)" != 000 ]] \
  || { echo "OpenBao did not come up after 3 minutes — check the '$COMPOSE_NAME' deployment logs in Dokploy, or:" >&2
       echo "  $(node_hint "$CP_NODE") docker service ps ${STACK_NAME}_openbao --no-trunc" >&2; exit 1; }

# --- initialize (once) -------------------------------------------------------

if [[ "$(bao_status)" == 501 ]]; then
  if [[ -f "$OPENBAO_INIT_FILE" ]]; then
    # Can't belong to this OpenBao, which has never been initialized.
    mv "$OPENBAO_INIT_FILE" "${OPENBAO_INIT_FILE}.stale"
    echo "== moved stale $OPENBAO_INIT_FILE aside to ${OPENBAO_INIT_FILE}.stale"
  fi
  echo "== initializing OpenBao"
  # With auto-unseal there are no unseal keys to hand out, only a recovery
  # key (needed for a few operator actions, e.g. generating a new root token).
  init="$(curl -sSf -X PUT "${OPENBAO_URL}/v1/sys/init" \
    -d '{"recovery_shares": 1, "recovery_threshold": 1}')"
  ( umask 077; printf '%s\n' "$init" >"$OPENBAO_INIT_FILE" )
  echo "== root token and recovery key saved to $OPENBAO_INIT_FILE"
elif [[ ! -f "$OPENBAO_INIT_FILE" ]]; then
  echo "OpenBao is already initialized, but $OPENBAO_INIT_FILE is missing, so there's no root token to configure it with." >&2
  echo "Restore that file, or wipe OpenBao (remove the '$COMPOSE_NAME' stack and its openbao-data volume) and re-run." >&2
  exit 1
fi

echo "== waiting for OpenBao to auto-unseal"
for _ in $(seq 1 24); do
  [[ "$(bao_status)" == 200 ]] && break
  sleep 5
done
[[ "$(bao_status)" == 200 ]] \
  || { echo "OpenBao is still sealed or not ready after 2 minutes (health: $(bao_status)) — check its logs:" >&2
       echo "  $(node_hint "$CP_NODE") docker service logs ${STACK_NAME}_openbao" >&2; exit 1; }

bao_api "auth/token/lookup-self" >/dev/null \
  || { echo "the root token in $OPENBAO_INIT_FILE was rejected — it belongs to a different OpenBao instance" >&2; exit 1; }

# --- KV mount + provider token role ------------------------------------------

if bao_api "sys/mounts" | jq -e --arg m "${OPENBAO_KV_MOUNT}/" '(.data // .) | has($m)' >/dev/null; then
  echo "== KV mount ${OPENBAO_KV_MOUNT}/ already exists"
else
  echo "== enabling KV v2 at ${OPENBAO_KV_MOUNT}/"
  bao_api "sys/mounts/${OPENBAO_KV_MOUNT}" -X POST \
    -d '{"type": "kv", "options": {"version": "2"}}' >/dev/null
fi

# Dokploy stores one token per provider and never renews it, so provider
# tokens are periodic (no max TTL) and orphans (they survive the root token
# being revoked). The role can only grant per-project policies, never root
# or default. Writing a role is an upsert, so this just re-applies it.
echo "== applying token role ${OPENBAO_PROVIDER_ROLE}"
bao_api "auth/token/roles/${OPENBAO_PROVIDER_ROLE}" -X POST \
  -d "$(jq -n --arg g "${OPENBAO_POLICY_PREFIX}*" \
    '{allowed_policies_glob: [$g], orphan: true, renewable: true,
      token_period: "768h", token_no_default_policy: true, token_type: "service"}')" >/dev/null

# Configs from earlier versions of stacks/openbao.hcl. Swarm refuses to
# remove one that a task still uses, so a failure just means the next run gets it.
for old in $(cp_exec docker config ls --format '{{.Name}}' | grep '^openbao-config-' | grep -vx "$OPENBAO_CONFIG" || true); do
  cp_exec docker config rm "$old" >/dev/null 2>&1 && echo "== removed old Swarm config $old" || true
done

echo "== OpenBao placement:"
cp_exec docker service ps --filter desired-state=running \
  --format '   {{.Name}} on {{.Node}} ({{.CurrentState}})' "${STACK_NAME}_openbao"
echo "== OpenBao up and unsealed (root token in $OPENBAO_INIT_FILE)"
echo "==   its UI: $(cp_ui_hint "$OPENBAO_PORT" /ui)"
echo "== next: when deploying an app, follow APP-PROJECT-SETUP.md to give its project a secrets provider"
