#!/usr/bin/env bash
# Points Dokploy's Roster app at $IMAGE, deploys it, and waits until the app
# answers at $ROSTER_URL. Run by web-app-ci.yml's deploy job, with the
# secrets and variables terraform/apps/roster sets on the repository:
# DOKPLOY_URL, DOKPLOY_API_KEY, APP_ID, REGISTRY_ADDR, REGISTRY_USER,
# REGISTRY_PASSWORD, ROSTER_URL.
set -euo pipefail

# The key goes in through a file descriptor, not argv.
api_get() {
  curl -sSf -H @<(printf 'x-api-key: %s\n' "$DOKPLOY_API_KEY") "${DOKPLOY_URL}/api/$1"
}
api_post() {
  curl -sSf -H @<(printf 'x-api-key: %s\n' "$DOKPLOY_API_KEY") \
    -H 'Content-Type: application/json' -d "$2" "${DOKPLOY_URL}/api/$1"
}

echo "running: $(api_get "application.one?applicationId=${APP_ID}" | jq -r .dockerImage)"
echo "deploying: $IMAGE"

api_post application.saveDockerProvider "$(jq -n --arg id "$APP_ID" --arg i "$IMAGE" \
  --arg r "$REGISTRY_ADDR" --arg u "$REGISTRY_USER" --arg p "$REGISTRY_PASSWORD" \
  '{applicationId: $id, dockerImage: $i, registryUrl: $r, username: $u, password: $p}')" >/dev/null
api_post application.deploy "$(jq -n --arg id "$APP_ID" '{applicationId: $id}')" >/dev/null

# Dokploy deploys in the background: wait for its status to settle.
status=""
for _ in $(seq 1 90); do
  sleep 5
  status="$(api_get "application.one?applicationId=${APP_ID}" | jq -r .applicationStatus)"
  case "$status" in
    done) break ;;
    error) echo "Dokploy reports the deploy failed: see the app's deployments in Dokploy" >&2; exit 1 ;;
  esac
done
[[ "$status" == done ]] || { echo "the deploy didn't finish within 7.5 minutes (status: $status)" >&2; exit 1; }

for _ in $(seq 1 30); do
  if curl -sf -o /dev/null -m 5 "${ROSTER_URL}/readyz"; then
    echo "deployed $IMAGE, answering at $ROSTER_URL"
    exit 0
  fi
  sleep 5
done
echo "deployed $IMAGE, but $ROSTER_URL/readyz doesn't answer" >&2
exit 1
