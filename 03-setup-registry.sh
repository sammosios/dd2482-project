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
# Credentials are generated on first run into .registry-credentials
# (gitignored, removed by teardown.sh) and reused afterwards. The htpasswd
# file reaches the service as an external Swarm config, named after a hash
# of the credentials, so changing them rolls out a new config instead of
# colliding with the old (immutable) one.
#
# Safe to re-run: reuses the project/compose/registry entries if they exist,
# and only redeploys when the compose file changed or the registry is down.
# Usage: ./03-setup-registry.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

require multipass curl jq openssl

REGISTRY_ADDR="127.0.0.1:${REGISTRY_PORT}"
PROJECT_NAME="infrastructure"
COMPOSE_NAME="registry"

vm_exists "$CP_NAME" || { echo "control plane VM not found — run 00-launch-cp-vm.sh first" >&2; exit 1; }
CP_IP="$(vm_ip "$CP_NAME")"

dokploy_api "$CP_IP" "cluster.getNodes" >/dev/null \
  || { echo "cannot reach Dokploy API on $CP_IP — run 01-dokploy-api-key.sh first" >&2; exit 1; }

cp_exec() {
  # Bare `multipass exec` has been seen to hang indefinitely (see PLAN.md),
  # so cap each call and retry on timeout. Only pass commands that are safe
  # to run twice, since a timed-out call may still have gone through.
  local attempt rc=0
  for attempt in 1 2 3; do
    with_timeout "${CP_EXEC_TIMEOUT:-60}" multipass exec "$CP_NAME" -- sudo "$@" && return 0 || rc=$?
    [[ "$rc" -eq 124 ]] || return "$rc"
    echo "  (multipass exec on $CP_NAME timed out, retry $attempt/3)" >&2
  done
  return 124
}

registry_status() {
  # HTTP status of the registry's API root as seen from the control plane:
  # 401 means up and enforcing auth, 000 means nothing is listening yet.
  with_timeout 15 multipass exec "$CP_NAME" -- \
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
  CP_EXEC_TIMEOUT=180 cp_exec bash -c "docker config inspect '${HTPASSWD_CONFIG}' >/dev/null 2>&1 \
    || { docker run --rm --entrypoint htpasswd httpd:2-alpine -Bbn '${REGISTRY_USER}' '${REGISTRY_PASS}' \
         | docker config create '${HTPASSWD_CONFIG}' - >/dev/null; }; rc=\$?; \
    docker image rm httpd:2-alpine >/dev/null 2>&1; exit \$rc"
fi

# --- compose file ------------------------------------------------------------

COMPOSE_FILE="$(cat <<EOF
services:
  registry:
    image: registry:3
    environment:
      REGISTRY_AUTH: htpasswd
      REGISTRY_AUTH_HTPASSWD_REALM: Registry
      REGISTRY_AUTH_HTPASSWD_PATH: /auth/htpasswd
      # Lets image deletes through the API, so 'registry garbage-collect'
      # can actually free disk later on.
      REGISTRY_STORAGE_DELETE_ENABLED: "true"
    ports:
      # Routing mesh (ingress): reachable on 127.0.0.1:${REGISTRY_PORT} from every node.
      - target: 5000
        published: ${REGISTRY_PORT}
        protocol: tcp
        mode: ingress
    volumes:
      - registry-data:/var/lib/registry
    configs:
      - source: htpasswd
        target: /auth/htpasswd
    deploy:
      replicas: 1
      placement:
        # registry-data is node-local: pin to the manager (the control
        # plane) so the task never lands on an empty volume elsewhere.
        constraints:
          - node.role == manager
      restart_policy:
        condition: any

volumes:
  registry-data:

configs:
  htpasswd:
    external: true
    name: ${HTPASSWD_CONFIG}
EOF
)"

# --- Dokploy project + compose resource --------------------------------------

projects="$(dokploy_api "$CP_IP" "project.all")"
ENV_ID="$(jq -r --arg p "$PROJECT_NAME" \
  'first(.[] | select(.name == $p) | .environments[0].environmentId) // empty' <<<"$projects")"

if [[ -n "$ENV_ID" ]]; then
  echo "== Dokploy project '$PROJECT_NAME' already exists"
else
  echo "== creating Dokploy project '$PROJECT_NAME'"
  ENV_ID="$(dokploy_api "$CP_IP" "project.create" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$PROJECT_NAME" '{name: $n, description: "Cluster infrastructure services"}')" \
    | jq -r '.environment.environmentId // empty')"
  [[ -n "$ENV_ID" ]] || { echo "project.create returned no environment id" >&2; exit 1; }
fi

COMPOSE_ID="$(jq -r --arg p "$PROJECT_NAME" --arg c "$COMPOSE_NAME" \
  'first(.[] | select(.name == $p) | .environments[].compose[] | select(.name == $c) | .composeId) // empty' <<<"$projects")"

if [[ -n "$COMPOSE_ID" ]]; then
  echo "== Dokploy compose '$COMPOSE_NAME' already exists"
else
  echo "== creating Dokploy compose '$COMPOSE_NAME' (type: stack)"
  COMPOSE_ID="$(dokploy_api "$CP_IP" "compose.create" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$COMPOSE_NAME" --arg e "$ENV_ID" \
      '{name: $n, appName: $n, environmentId: $e, composeType: "stack", sourceType: "raw",
        description: "Container registry, pinned to the manager node"}')" \
    | jq -r '.composeId // empty')"
  [[ -n "$COMPOSE_ID" ]] || { echo "compose.create returned no compose id" >&2; exit 1; }
fi

compose="$(dokploy_api "$CP_IP" "compose.one" -G --data-urlencode "composeId=${COMPOSE_ID}")"
# Dokploy suffixes appName with a random id; it's also the Swarm stack name.
STACK_NAME="$(jq -r '.appName' <<<"$compose")"
current_file="$(jq -r '.composeFile // ""' <<<"$compose")"

if [[ "$current_file" == "$COMPOSE_FILE" && "$(registry_status)" == 401 ]]; then
  echo "== registry already deployed and up to date, skipping deploy"
else
  echo "== deploying registry stack"
  dokploy_api "$CP_IP" "compose.update" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg id "$COMPOSE_ID" --arg f "$COMPOSE_FILE" \
      '{composeId: $id, composeFile: $f, composeType: "stack", sourceType: "raw"}')" >/dev/null
  dokploy_api "$CP_IP" "compose.deploy" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg id "$COMPOSE_ID" '{composeId: $id}')" >/dev/null

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
REGISTRY_ID="$(dokploy_api "$CP_IP" "registry.all" \
  | jq -r --arg u "$REGISTRY_ADDR" 'first(.[] | select(.registryUrl == $u) | .registryId) // empty')"

registry_body="$(jq -n --arg u "$REGISTRY_USER" --arg p "$REGISTRY_PASS" --arg url "$REGISTRY_ADDR" \
  '{registryName: "cluster-registry", username: $u, password: $p, registryUrl: $url,
    registryType: "cloud", imagePrefix: null}')"

if [[ -n "$REGISTRY_ID" ]]; then
  echo "== registry already registered in Dokploy, syncing credentials"
  dokploy_api "$CP_IP" "registry.update" -X POST -H 'Content-Type: application/json' \
    -d "$(jq --arg id "$REGISTRY_ID" '. + {registryId: $id}' <<<"$registry_body")" >/dev/null
else
  echo "== registering ${REGISTRY_ADDR} in Dokploy"
  dokploy_api "$CP_IP" "registry.create" -X POST -H 'Content-Type: application/json' \
    -d "$registry_body" >/dev/null
fi

echo "== registry service placement:"
cp_exec docker service ps --filter desired-state=running \
  --format '   {{.Name}} on {{.Node}} ({{.CurrentState}})' "${STACK_NAME}_registry"
echo "== registry up at ${REGISTRY_ADDR} on every node (user: ${REGISTRY_USER}, password in ${REGISTRY_CREDS_FILE})"
echo "== next: select 'cluster-registry' in each application's Cluster settings in Dokploy"
