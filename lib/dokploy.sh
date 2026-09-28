#!/usr/bin/env bash
# Dokploy "infrastructure as code" helpers: every cluster service is a
# compose file under stacks/, deployed as a Dokploy Compose resource of type
# Stack (a Swarm stack) with a raw source. The files in git are the source
# of truth; these helpers make Dokploy match them, idempotently. See
# DESIGN.md "Services as code". Sourced after lib/common.sh.
set -euo pipefail

STACKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/stacks"

render_template() {
  # render_template <file> VAR... - prints <file> with each ${VAR} replaced
  # by that shell variable's value. Only the named variables are touched,
  # so the file can still hold $$-escaped shell for the container itself.
  # Fails on an unset variable or a ${VAR} left without a value, so a typo
  # can't reach the cluster as a literal "${VAR}".
  local file="$1" out name; shift
  out="$(<"$file")"
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || { echo "render_template: $name is not set (for $file)" >&2; return 1; }
    out="${out//"\${$name}"/"${!name}"}"
  done
  if grep -qE '(^|[^$])\$\{[A-Za-z_][A-Za-z0-9_]*\}' <<<"$out"; then
    echo "render_template: unrendered variable(s) left in $file:" >&2
    grep -oE '(^|[^$])\$\{[A-Za-z_][A-Za-z0-9_]*\}' <<<"$out" | sort -u >&2
    return 1
  fi
  printf '%s' "$out"
}

dokploy_stack_sync() {
  # dokploy_stack_sync <cp_ip> <project> <compose name> <description> <compose file>
  # Makes sure Dokploy has <project> containing a stack-type, raw-source
  # compose resource <compose name> whose file is exactly <compose file>,
  # creating either if missing. Does not deploy. Sets:
  #   STACK_COMPOSE_ID  - the compose resource's id
  #   STACK_NAME        - Dokploy's appName (suffixed with a random id), which
  #                       is also the Swarm stack name: services are
  #                       ${STACK_NAME}_<service>
  #   STACK_CHANGED     - 1 if the file was (re)uploaded, i.e. a deploy is due
  local ip="$1" project="$2" name="$3" description="$4" file="$5"
  local projects env_id compose current

  projects="$(dokploy_api "$ip" "project.all")"
  env_id="$(jq -r --arg p "$project" \
    'first(.[] | select(.name == $p) | .environments[0].environmentId) // empty' <<<"$projects")"

  if [[ -n "$env_id" ]]; then
    echo "== Dokploy project '$project' already exists"
  else
    echo "== creating Dokploy project '$project'"
    env_id="$(dokploy_api "$ip" "project.create" -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "$project" '{name: $n, description: "Cluster infrastructure services"}')" \
      | jq -r '.environment.environmentId // empty')"
    [[ -n "$env_id" ]] || { echo "project.create returned no environment id" >&2; return 1; }
  fi

  STACK_COMPOSE_ID="$(jq -r --arg p "$project" --arg c "$name" \
    'first(.[] | select(.name == $p) | .environments[].compose[] | select(.name == $c) | .composeId) // empty' <<<"$projects")"

  if [[ -n "$STACK_COMPOSE_ID" ]]; then
    echo "== Dokploy compose '$name' already exists"
  else
    echo "== creating Dokploy compose '$name' (type: stack)"
    STACK_COMPOSE_ID="$(dokploy_api "$ip" "compose.create" -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "$name" --arg e "$env_id" --arg d "$description" \
        '{name: $n, appName: $n, environmentId: $e, composeType: "stack", sourceType: "raw", description: $d}')" \
      | jq -r '.composeId // empty')"
    [[ -n "$STACK_COMPOSE_ID" ]] || { echo "compose.create returned no compose id" >&2; return 1; }
  fi

  compose="$(dokploy_api "$ip" "compose.one" -G --data-urlencode "composeId=${STACK_COMPOSE_ID}")"
  STACK_NAME="$(jq -r '.appName' <<<"$compose")"
  current="$(jq -r '.composeFile // ""' <<<"$compose")"

  if [[ "$current" == "$file" ]]; then
    STACK_CHANGED=0
  else
    echo "== uploading compose file for '$name'"
    dokploy_api "$ip" "compose.update" -X POST -H 'Content-Type: application/json' \
      -d "$(jq -n --arg id "$STACK_COMPOSE_ID" --arg f "$file" \
        '{composeId: $id, composeFile: $f, composeType: "stack", sourceType: "raw"}')" >/dev/null
    STACK_CHANGED=1
  fi
}

dokploy_stack_deploy() {
  # dokploy_stack_deploy <cp_ip> <compose id> - queues a deployment. Returns
  # before the stack is up; callers wait on their own health check.
  dokploy_api "$1" "compose.deploy" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg id "$2" '{composeId: $id}')" >/dev/null
}
