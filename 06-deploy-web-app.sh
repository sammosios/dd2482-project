#!/usr/bin/env bash
# Deploys the example web app (web-app/, "Roster") and its database, the way
# the CI runner will later (see DESIGN.md, "Web app delivery"):
#   - builds the image of the last commit that touched web-app/ on a worker,
#     and pushes it to the cluster registry as roster:<commit>
#   - makes sure Dokploy has a project with a PostgreSQL service, and an
#     application that runs that image (Docker provider) with its
#     environment, replicas and domains; then deploys it
#   - waits until every replica runs the new image and the app answers
#     through Traefik
# Until the CI runner exists, re-running this after committing a change to
# web-app/ is how the app gets redeployed.
#
# The app's first admin gets a generated password, kept in
# .web-app-credentials (gitignored, removed by teardown.sh); name and email
# default to the Dokploy admin's from .dokploy-admin.env.
#
# Safe to re-run: reuses whatever exists (including a project, database and
# app set up by hand under the same names), skips the build when the
# registry already has the image, and only redeploys when a setting changed
# or the app isn't running that image.
# Usage: ./06-deploy-web-app.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

require multipass curl jq git openssl

PROJECT_NAME="roster"
DB_SERVICE="roster-db"
APP_SERVICE="roster-app"
REPLICAS=2
APP_PORT=8080
REGISTRY_ADDR="127.0.0.1:${REGISTRY_PORT}"

vm_exists "$CP_NAME" || { echo "control plane VM not found — run 00-launch-cp-vm.sh first" >&2; exit 1; }
CP_IP="$(vm_ip "$CP_NAME")"

dokploy_api "$CP_IP" "cluster.getNodes" >/dev/null \
  || { echo "cannot reach Dokploy API on $CP_IP — run 01-dokploy-api-key.sh first" >&2; exit 1; }

[[ -f "$REGISTRY_CREDS_FILE" ]] \
  || { echo "$REGISTRY_CREDS_FILE not found — run 03-setup-registry.sh first" >&2; exit 1; }
REGISTRY_USER="$(env_file_value "$REGISTRY_CREDS_FILE" REGISTRY_USERNAME)"
REGISTRY_PASS="$(env_file_value "$REGISTRY_CREDS_FILE" REGISTRY_PASSWORD)"

# roster.localhost is for browsers that reach Traefik through a local
# forward (forward.sh, a gitignored WSL-only helper). The sslip.io name
# resolves straight to the control plane, for hosts that can reach the VM
# network: macOS, Linux, or curl inside WSL.
LOCAL_HOST="roster.localhost"
DIRECT_HOST="roster.${CP_IP}.sslip.io"

api_get() { dokploy_api "$CP_IP" "$1" -G --data-urlencode "$2"; }
api_post() { dokploy_api "$CP_IP" "$1" -X POST -H 'Content-Type: application/json' -d "$2"; }

node_exec() {
  # node_exec <vm> <command...>: 03's cp_exec, on any node. Bare
  # `multipass exec` has been seen to hang (PLAN.md), so each call is capped
  # and retried; only for short commands that are safe to run twice.
  local vm="$1" attempt rc=0
  shift
  for attempt in 1 2 3; do
    with_timeout 60 multipass exec "$vm" -- sudo "$@" && return 0 || rc=$?
    [[ "$rc" -eq 124 ]] || return "$rc"
    echo "  (multipass exec on $vm timed out, retry $attempt/3)" >&2
  done
  return 124
}

# --- image ---------------------------------------------------------------------

# Tagged with the last commit that touched web-app/ and built from that
# commit's files (git archive), not the working tree: the tag always says
# exactly what's in the image, and commits elsewhere don't cause a rebuild.
TAG="$(git log -1 --format=%h -- web-app)"
[[ -n "$TAG" ]] || { echo "no commit contains web-app/ yet" >&2; exit 1; }
APP_IMAGE="${REGISTRY_ADDR}/roster:${TAG}"
if [[ -n "$(git status --porcelain -- web-app)" ]]; then
  echo "== note: web-app/ has uncommitted changes; they won't be deployed until you commit them"
fi

registry_has_image() {
  # Port 5000 is published on every node's IP (routing mesh), so ask the
  # registry straight from here. Credentials go through stdin, not argv.
  local code
  code="$(printf 'user = "%s:%s"\n' "$REGISTRY_USER" "$REGISTRY_PASS" \
    | curl -s -K - -I -m 10 -o /dev/null -w '%{http_code}' \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
        "http://${CP_IP}:${REGISTRY_PORT}/v2/roster/manifests/${TAG}" || true)"
  [[ "$code" == 200 ]]
}

if registry_has_image; then
  echo "== registry already has $APP_IMAGE, skipping the build"
else
  # On a worker when there is one: the control plane has 2 GB of RAM and
  # runs Dokploy. Every node reaches the registry on its own
  # 127.0.0.1:5000, so the worker pushes directly.
  BUILD_VM="$(worker_name 1)"
  vm_exists "$BUILD_VM" || BUILD_VM="$CP_NAME"
  echo "== building $APP_IMAGE on $BUILD_VM"

  # The source travels as a file: piping more than 2 MiB through
  # `multipass exec` gets cut off (PLAN.md), and the multipass snap can only
  # read non-hidden files under $HOME.
  src="$(mktemp "${HOME}/roster-src-XXXXXX")"
  trap 'rm -f "$src"' EXIT
  git archive --format=tar -o "$src" "$TAG" web-app
  node_exec "$BUILD_VM" rm -rf /tmp/roster-build /tmp/roster-src.tar
  multipass transfer "$src" "${BUILD_VM}:/tmp/roster-src.tar"
  node_exec "$BUILD_VM" sh -c 'mkdir /tmp/roster-build && tar -xf /tmp/roster-src.tar -C /tmp/roster-build'

  # Not capped like node_exec: on a fresh node the build first pulls the Go
  # image, which can take minutes, and its output is worth seeing live.
  multipass exec "$BUILD_VM" -- sudo docker build -t "$APP_IMAGE" /tmp/roster-build/web-app
  printf '%s' "$REGISTRY_PASS" \
    | multipass exec "$BUILD_VM" -- sudo docker login "$REGISTRY_ADDR" -u "$REGISTRY_USER" --password-stdin >/dev/null
  multipass exec "$BUILD_VM" -- sudo docker push "$APP_IMAGE"
  node_exec "$BUILD_VM" rm -rf /tmp/roster-build /tmp/roster-src.tar
  registry_has_image || { echo "pushed $APP_IMAGE, but the registry doesn't have it" >&2; exit 1; }
fi

# --- Dokploy project -----------------------------------------------------------

projects="$(dokploy_api "$CP_IP" "project.all")"
ENV_ID="$(jq -r --arg p "$PROJECT_NAME" \
  'first(.[] | select(.name == $p) | .environments[0].environmentId) // empty' <<<"$projects")"
if [[ -n "$ENV_ID" ]]; then
  echo "== Dokploy project '$PROJECT_NAME' already exists"
else
  echo "== creating Dokploy project '$PROJECT_NAME'"
  ENV_ID="$(api_post project.create "$(jq -n --arg n "$PROJECT_NAME" \
    '{name: $n, description: "Roster, the example web app, and its database"}')" \
    | jq -r '.environment.environmentId // empty')"
  [[ -n "$ENV_ID" ]] || { echo "project.create returned no environment id" >&2; exit 1; }
  projects="$(dokploy_api "$CP_IP" "project.all")"
fi
environment="$(jq --arg e "$ENV_ID" 'first(.[].environments[] | select(.environmentId == $e))' <<<"$projects")"

# --- database --------------------------------------------------------------------

wait_until_done() {
  # wait_until_done <endpoint> <id=...> <label>: Dokploy deploys in the
  # background, so poll the service's status until the deployment is over.
  local status=""
  for _ in $(seq 1 60); do
    status="$(api_get "$1" "$2" | jq -r .applicationStatus)"
    case "$status" in
      done) return 0 ;;
      error) echo "deploying $3 failed — see its Deployments and Logs tabs in Dokploy" >&2; exit 1 ;;
    esac
    sleep 5
  done
  echo "$3 is still '$status' after 5 minutes" >&2
  exit 1
}

# project.all only lists the ids of database services: find ours by name.
PG_ID=""
for id in $(jq -r '(.postgres // [])[].postgresId' <<<"$environment"); do
  if [[ "$(api_get postgres.one "postgresId=$id" | jq -r .name)" == "$DB_SERVICE" ]]; then
    PG_ID="$id"
    break
  fi
done
if [[ -n "$PG_ID" ]]; then
  echo "== database '$DB_SERVICE' already exists"
else
  echo "== creating database '$DB_SERVICE'"
  # An empty password makes Dokploy generate one of letters and digits:
  # safe inside the connection URL, which Dokploy doesn't URL-encode.
  PG_ID="$(api_post postgres.create "$(jq -n --arg n "$DB_SERVICE" --arg e "$ENV_ID" \
    '{name: $n, appName: $n, environmentId: $e, databaseName: "roster", databaseUser: "roster",
      databasePassword: "", dockerImage: "postgres:18", description: "PostgreSQL for Roster"}')" \
    | jq -r '.postgresId // empty')"
  [[ -n "$PG_ID" ]] || { echo "postgres.create returned no id" >&2; exit 1; }
fi

pg="$(api_get postgres.one "postgresId=$PG_ID")"
if [[ "$(jq -r .applicationStatus <<<"$pg")" != "done" ]]; then
  echo "== deploying database '$DB_SERVICE'"
  api_post postgres.deploy "$(jq -n --arg id "$PG_ID" '{postgresId: $id}')" >/dev/null
  wait_until_done postgres.one "postgresId=$PG_ID" "database '$DB_SERVICE'"
fi
# The app reaches the database by its Swarm service name over Dokploy's
# network: the URL the UI shows as "Internal Connection URL".
DATABASE_URL="$(jq -r '"postgresql://\(.databaseUser):\(.databasePassword)@\(.appName):5432/\(.databaseName)"' <<<"$pg")"

# --- application -------------------------------------------------------------------

APP_ID="$(jq -r --arg n "$APP_SERVICE" \
  'first((.applications // [])[] | select(.name == $n) | .applicationId) // empty' <<<"$environment")"
if [[ -n "$APP_ID" ]]; then
  echo "== application '$APP_SERVICE' already exists"
else
  echo "== creating application '$APP_SERVICE'"
  APP_ID="$(api_post application.create "$(jq -n --arg n "$APP_SERVICE" --arg e "$ENV_ID" \
    '{name: $n, appName: $n, environmentId: $e, description: "Roster, the example web app (web-app/)"}')" \
    | jq -r '.applicationId // empty')"
  [[ -n "$APP_ID" ]] || { echo "application.create returned no id" >&2; exit 1; }
fi
app="$(api_get application.one "applicationId=$APP_ID")"
# Dokploy suffixes appName with a random id; it's also the Swarm service name.
APP_SWARM_SERVICE="$(jq -r .appName <<<"$app")"

# --- the app's first admin -----------------------------------------------------------

# The app only reads ADMIN_* on its first start against an empty database, to
# create the first admin; after that they change nothing.
current_env() { env_file_value <(jq -r '.env // ""' <<<"$app") "$1" || true; }

if [[ -f "$WEB_APP_CREDS_FILE" ]]; then
  ADMIN_EMAIL="$(env_file_value "$WEB_APP_CREDS_FILE" ADMIN_EMAIL || true)"
  ADMIN_NAME="$(env_file_value "$WEB_APP_CREDS_FILE" ADMIN_NAME || true)"
  ADMIN_PASSWORD="$(env_file_value "$WEB_APP_CREDS_FILE" ADMIN_PASSWORD || true)"
  [[ -n "$ADMIN_EMAIL" && -n "$ADMIN_PASSWORD" ]] \
    || { echo "$WEB_APP_CREDS_FILE is missing ADMIN_EMAIL or ADMIN_PASSWORD — delete it to regenerate" >&2; exit 1; }
  echo "== reusing the app's admin credentials from $WEB_APP_CREDS_FILE"
else
  if [[ -n "$(current_env ADMIN_PASSWORD)" ]]; then
    # Set up by hand before: keep that admin rather than inventing a
    # password its database has never seen.
    ADMIN_EMAIL="$(current_env ADMIN_EMAIL)"
    ADMIN_NAME="$(current_env ADMIN_NAME)"
    ADMIN_PASSWORD="$(current_env ADMIN_PASSWORD)"
    how="kept the admin credentials the app already had"
  else
    ADMIN_EMAIL="" ADMIN_NAME=""
    if [[ -f .dokploy-admin.env ]]; then
      ADMIN_EMAIL="$(env_file_value .dokploy-admin.env DOKPLOY_ADMIN_EMAIL || true)"
      ADMIN_NAME="$(env_file_value .dokploy-admin.env DOKPLOY_ADMIN_NAME || true)"
    fi
    # Hex only, so it's safe in the env text Dokploy parses.
    ADMIN_PASSWORD="$(openssl rand -hex 12)"
    how="generated the app's admin credentials"
  fi
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
  ADMIN_NAME="${ADMIN_NAME:-Administrator}"
  ( umask 077
    printf 'ADMIN_EMAIL=%s\nADMIN_NAME="%s"\nADMIN_PASSWORD=%s\n' "$ADMIN_EMAIL" "$ADMIN_NAME" "$ADMIN_PASSWORD" \
      >"$WEB_APP_CREDS_FILE" )
  echo "== $how into $WEB_APP_CREDS_FILE"
fi

# --- application settings ----------------------------------------------------------

changed=0

# Run the prebuilt image. These are the credentials Dokploy logs in with to
# pull it, and hands to Swarm so every worker can pull it too.
if ! jq -e --arg i "$APP_IMAGE" --arg r "$REGISTRY_ADDR" --arg u "$REGISTRY_USER" --arg p "$REGISTRY_PASS" \
    '.sourceType == "docker" and .dockerImage == $i and .registryUrl == $r and .username == $u and .password == $p' \
    <<<"$app" >/dev/null; then
  echo "== pointing '$APP_SERVICE' at $APP_IMAGE"
  api_post application.saveDockerProvider "$(jq -n --arg id "$APP_ID" --arg i "$APP_IMAGE" \
    --arg r "$REGISTRY_ADDR" --arg u "$REGISTRY_USER" --arg p "$REGISTRY_PASS" \
    '{applicationId: $id, dockerImage: $i, registryUrl: $r, username: $u, password: $p}')" >/dev/null
  changed=1
fi

ENV_VARS="$(printf 'DATABASE_URL=%s\nADMIN_EMAIL=%s\nADMIN_NAME="%s"\nADMIN_PASSWORD=%s' \
  "$DATABASE_URL" "$ADMIN_EMAIL" "$ADMIN_NAME" "$ADMIN_PASSWORD")"
if [[ "$(jq -r '.env // ""' <<<"$app")" != "$ENV_VARS" ]]; then
  echo "== saving '$APP_SERVICE' environment variables"
  # createEnvFile only matters when Dokploy builds the image; this one's prebuilt.
  api_post application.saveEnvironment "$(jq -n --arg id "$APP_ID" --arg env "$ENV_VARS" \
    '{applicationId: $id, env: $env, buildArgs: "", buildSecrets: "", createEnvFile: false}')" >/dev/null
  changed=1
fi

if [[ "$(jq -r .replicas <<<"$app")" != "$REPLICAS" ]]; then
  echo "== setting '$APP_SERVICE' to $REPLICAS replicas"
  api_post application.update "$(jq -n --arg id "$APP_ID" --argjson n "$REPLICAS" \
    '{applicationId: $id, replicas: $n}')" >/dev/null
  changed=1
fi

# Domains reach Traefik as soon as they're created: no redeploy needed.
domains="$(api_get domain.byApplicationId "applicationId=$APP_ID")"
for host in "$LOCAL_HOST" "$DIRECT_HOST"; do
  if jq -e --arg h "$host" 'any(.[]; .host == $h)' <<<"$domains" >/dev/null; then
    echo "== domain $host already set"
  else
    echo "== adding domain $host"
    api_post domain.create "$(jq -n --arg h "$host" --arg id "$APP_ID" --argjson port "$APP_PORT" \
      '{host: $h, port: $port, path: "/", https: false, certificateType: "none",
        domainType: "application", applicationId: $id}')" >/dev/null
  fi
done

# --- deploy --------------------------------------------------------------------------

service_state() {
  # "<version>|<image>|<update state>|<running>/<desired>" of the app's
  # Swarm service, or "" while it doesn't exist yet.
  node_exec "$CP_NAME" sh -c "
    docker service inspect '$APP_SWARM_SERVICE' 2>/dev/null \
      --format '{{.Version.Index}}|{{.Spec.TaskTemplate.ContainerSpec.Image}}|{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}|' \
      | tr -d '\n'
    docker service ls --filter 'name=$APP_SWARM_SERVICE' --format '{{.Replicas}}' 2>/dev/null" || true
}

wait_for_rollout() {
  # wait_for_rollout <service version before the deploy>. Dokploy pulls the
  # image and updates the Swarm service in the background; Swarm then
  # replaces the replicas one at a time, each only once its healthcheck
  # passes, and rolls back if one doesn't. Done when every replica runs
  # the new image.
  local before="$1" state="" version image update running
  for _ in $(seq 1 60); do
    [[ "$(api_get application.one "applicationId=$APP_ID" | jq -r .applicationStatus)" != error ]] \
      || { echo "the deployment failed — see the app's Deployments tab in Dokploy" >&2; exit 1; }
    state="$(service_state)"
    IFS='|' read -r version image update running <<<"$state"
    if [[ -n "$version" && "$version" != "$before" ]]; then
      if [[ "${image%%@*}" != "$APP_IMAGE" || "$update" == rollback_* || "$update" == paused ]]; then
        echo "Swarm rolled the update back: the new replicas didn't get healthy — see the app's Logs tab in Dokploy" >&2
        exit 1
      fi
      [[ "$update" != updating && "$running" == "${REPLICAS}/${REPLICAS}" ]] && return 0
    fi
    sleep 5
  done
  echo "the app didn't converge on $APP_IMAGE within 5 minutes (last seen: ${state:-no service})" >&2
  exit 1
}

IFS='|' read -r version image _ _ <<<"$(service_state)"
if [[ "$changed" -eq 0 && "${image%%@*}" == "$APP_IMAGE" && "$(jq -r .applicationStatus <<<"$app")" == "done" ]]; then
  echo "== '$APP_SERVICE' already runs $APP_IMAGE, nothing to deploy"
else
  echo "== deploying '$APP_SERVICE' ($APP_IMAGE, $REPLICAS replicas)"
  api_post application.deploy "$(jq -n --arg id "$APP_ID" --arg t "$TAG" \
    '{applicationId: $id, title: ("Deploy roster:" + $t), description: "06-deploy-web-app.sh"}')" >/dev/null
  wait_for_rollout "$version"
fi

# --- check ---------------------------------------------------------------------------

# Through Traefik, like a browser, but with the name pinned to the control
# plane's IP instead of looked up: no dependence on DNS (see DESIGN.md).
echo "== checking http://${LOCAL_HOST}/readyz through Traefik"
ok=0
for _ in $(seq 1 24); do
  if curl -fs -m 5 -o /dev/null --resolve "${LOCAL_HOST}:80:${CP_IP}" "http://${LOCAL_HOST}/readyz"; then
    ok=1
    break
  fi
  sleep 5
done
[[ "$ok" -eq 1 ]] || { echo "the app doesn't answer through Traefik — see its Logs and Domains tabs in Dokploy" >&2; exit 1; }

echo "== Roster is up: $APP_IMAGE, $REPLICAS replicas"
if [[ -x ./forward.sh ]]; then
  echo "==   from Windows (while ./forward.sh runs):   http://${LOCAL_HOST}:${FORWARD_HTTP_PORT}"
fi
echo "==   where the VM network is reachable:        http://${DIRECT_HOST}"
echo "==   sign in as ${ADMIN_EMAIL}, password in $(basename "$WEB_APP_CREDS_FILE")"
