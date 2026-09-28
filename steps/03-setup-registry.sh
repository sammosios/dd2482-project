#!/usr/bin/env bash
# Deploys the cluster's container registry and registers it with Dokploy, so
# every node can pull images Dokploy builds. See DESIGN.md for the why:
#   - a Dokploy Compose resource of type Stack (a Swarm service), with port
#     5000 published through the routing mesh, so every node reaches it on
#     its own 127.0.0.1:5000 - plain HTTP on loopback, no TLS or
#     insecure-registries setup per node
#   - pinned to the manager (the control plane), since its volume is
#     node-local and the control plane is the one node never scaled away
#   - always 127.0.0.1, never localhost (moby/moby#53091 on Docker < 29.8.0)
#
# Port 5000 is open on every node's IP, so the registry uses htpasswd auth.
# Credentials are generated on first run into the target's state
# (.state/<target>/registry-credentials) and reused afterwards. The htpasswd
# file reaches the service as an external Swarm config, named after a hash
# of the credentials, so changing them rolls out a new config instead of
# colliding with the old (immutable) one.
#
# The compose file itself is stacks/registry.yml (see lib/dokploy.sh).
#
# Safe to re-run: reuses the project/compose/registry entries if they exist,
# and only redeploys when the compose file changed or the registry is down.
# Usage: <target>/03-setup-registry.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source lib/common.sh
source lib/dokploy.sh

require curl jq openssl
target_require

REGISTRY_ADDR="127.0.0.1:${REGISTRY_PORT}"
PROJECT_NAME="infrastructure"
COMPOSE_NAME="registry"

load_cp
require_dokploy_api

registry_status() {
  # HTTP status of the registry's API root as seen from the control plane:
  # 401 means up and enforcing auth, 000 means nothing is listening yet.
  with_timeout 15 node_run "$CP_NODE" \
    curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${REGISTRY_ADDR}/v2/" || true
}

# --- credentials -------------------------------------------------------------

if [[ -f "$REGISTRY_CREDS_FILE" ]]; then
  REGISTRY_USER="$(env_file_value "$REGISTRY_CREDS_FILE" REGISTRY_USERNAME)"
  REGISTRY_PASS="$(env_file_value "$REGISTRY_CREDS_FILE" REGISTRY_PASSWORD)"
  [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASS" ]] \
    || { echo "$REGISTRY_CREDS_FILE is missing REGISTRY_USERNAME or REGISTRY_PASSWORD — delete it to regenerate" >&2; exit 1; }
  echo "== reusing registry credentials from $REGISTRY_CREDS_FILE"
else
  # Hex only, so the password is safe to pass through htpasswd's argv and
  # the shell/JSON quoting below without escaping.
  REGISTRY_USER="dokploy"
  REGISTRY_PASS="$(openssl rand -hex 24)"
  ( umask 077
    printf 'REGISTRY_USERNAME=%s\nREGISTRY_PASSWORD=%s\n' "$REGISTRY_USER" "$REGISTRY_PASS" >"$REGISTRY_CREDS_FILE" )
  echo "== generated registry credentials into $REGISTRY_CREDS_FILE"
fi

# --- htpasswd as a Swarm config ----------------------------------------------

creds_hash="$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASS" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-12)"
HTPASSWD_CONFIG="registry-htpasswd-${creds_hash}"

if cp_exec docker config inspect "$HTPASSWD_CONFIG" >/dev/null 2>&1; then
  echo "== Swarm config $HTPASSWD_CONFIG already exists"
else
  echo "== creating Swarm config $HTPASSWD_CONFIG"
  # The registry image no longer ships htpasswd, and the registry only
  # accepts bcrypt entries, so borrow httpd's copy for one run. Re-checks
  # for the config remotely, so a retry after a timeout is harmless. Longer
  # timeout, since the first run pulls httpd.
  NODE_EXEC_TIMEOUT=180 cp_exec bash -c "docker config inspect '${HTPASSWD_CONFIG}' >/dev/null 2>&1 \
    || { docker run --rm --entrypoint htpasswd httpd:2-alpine -Bbn '${REGISTRY_USER}' '${REGISTRY_PASS}' \
         | docker config create '${HTPASSWD_CONFIG}' - >/dev/null; }; rc=\$?; \
    docker image rm httpd:2-alpine >/dev/null 2>&1; exit \$rc"
fi

# --- Dokploy project + compose resource --------------------------------------

# Rendered into a variable first: a failed render inside a command argument
# wouldn't trip set -e.
COMPOSE_FILE="$(render_template "$STACKS_DIR/registry.yml" REGISTRY_PORT HTPASSWD_CONFIG)"
dokploy_stack_sync "$PROJECT_NAME" "$COMPOSE_NAME" \
  "Container registry, pinned to the manager node" "$COMPOSE_FILE"

if [[ "$STACK_CHANGED" == 0 && "$(registry_status)" == 401 ]]; then
  echo "== registry already deployed and up to date, skipping deploy"
else
  echo "== deploying registry stack"
  dokploy_stack_deploy "$STACK_COMPOSE_ID"

  # compose.deploy only queues the deployment, so wait for the registry itself.
  echo "== waiting for registry on ${REGISTRY_ADDR}"
  for _ in $(seq 1 36); do
    [[ "$(registry_status)" == 401 ]] && break
    sleep 5
  done
  [[ "$(registry_status)" == 401 ]] \
    || { echo "registry did not come up after 3 minutes — check the '$COMPOSE_NAME' deployment logs in Dokploy" >&2; exit 1; }
fi

# --- register with Dokploy ---------------------------------------------------

# registry.create/update run `docker login` against the registry straight
# away, which is why this comes after the deploy, not before.
REGISTRY_ID="$(dokploy_api "registry.all" \
  | jq -r --arg u "$REGISTRY_ADDR" 'first(.[] | select(.registryUrl == $u) | .registryId) // empty')"

registry_body="$(jq -n --arg u "$REGISTRY_USER" --arg p "$REGISTRY_PASS" --arg url "$REGISTRY_ADDR" \
  '{registryName: "cluster-registry", username: $u, password: $p, registryUrl: $url,
    registryType: "cloud", imagePrefix: null}')"

if [[ -n "$REGISTRY_ID" ]]; then
  echo "== registry already registered in Dokploy, syncing credentials"
  dokploy_api "registry.update" -X POST -H 'Content-Type: application/json' \
    -d "$(jq --arg id "$REGISTRY_ID" '. + {registryId: $id}' <<<"$registry_body")" >/dev/null
else
  echo "== registering ${REGISTRY_ADDR} in Dokploy"
  dokploy_api "registry.create" -X POST -H 'Content-Type: application/json' \
    -d "$registry_body" >/dev/null
fi

echo "== registry service placement:"
cp_exec docker service ps --filter desired-state=running \
  --format '   {{.Name}} on {{.Node}} ({{.CurrentState}})' "${STACK_NAME}_registry"
echo "== registry up at ${REGISTRY_ADDR} on every node (user: ${REGISTRY_USER}, password in ${REGISTRY_CREDS_FILE})"
echo "== next: select 'cluster-registry' in each application's Cluster settings in Dokploy"
