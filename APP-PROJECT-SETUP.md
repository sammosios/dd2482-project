# Setting up an app project's secrets

Follow this when deploying an app to the cluster. It gives the app its own Dokploy project and its own OpenBao secrets provider, so the app's env can reference secrets as `${{vault.bao-<name>.<name>/<path>:<FIELD>}}`. For why it's built this way, see DESIGN.md "Secrets: OpenBao".

For project `<name>` you create:

- the Dokploy project `<name>`
- an OpenBao policy `dokploy-project-<name>` that can read, and list for Dokploy's autocomplete, only `secret/<name>/*`
- a Dokploy secrets provider `bao-<name>`, assigned to that project only, holding a token issued with that policy

That gives two separate protections. Dokploy won't let another project use `bao-<name>`, and even with a wrong assignment the token can't read anything outside `secret/<name>/`.

## Prerequisites

The cluster is up through `05-setup-openbao.sh`. It creates the KV mount at `secret/`, the `dokploy-provider` token role, and `.openbao-init.json` with the root token that the helpers below use.

## 0. Shell setup

Run everything in **bash** from the repo root, since the helpers are bash:

```bash
bash
source lib/common.sh
source lib/openbao.sh

NAME=myapp   # lowercase letters, digits and dashes, max 40 chars; not "infrastructure"
POLICY="${OPENBAO_POLICY_PREFIX}${NAME}"
PROVIDER="bao-${NAME}"
CP_IP="$(vm_ip "$CP_NAME")"

# Both should succeed: Dokploy API reachable, OpenBao unsealed (200)
dokploy_api "$CP_IP" "cluster.getNodes" >/dev/null && echo dokploy ok
bao_status
```

The name ends up as a KV path segment, a policy name and part of a Dokploy provider name, which is why it has to be lowercase, digits and dashes.

## 1. Dokploy project

Skip this step if the project already exists. `project.create` doesn't return the ID reliably, so look it up afterwards:

```bash
dokploy_api "$CP_IP" "project.create" -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n --arg n "$NAME" '{name: $n, description: "App project"}')" >/dev/null

PROJECT_ID="$(dokploy_api "$CP_IP" "project.all" \
  | jq -r --arg p "$NAME" 'first(.[] | select(.name == $p) | .projectId) // empty')"
echo "$PROJECT_ID"
```

## 2. OpenBao policy

This step is safe to re-apply.

```bash
policy_hcl="$(cat <<EOF
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "${OPENBAO_KV_MOUNT}/data/${NAME}/*" {
  capabilities = ["read"]
}
path "${OPENBAO_KV_MOUNT}/metadata/${NAME}/*" {
  capabilities = ["read", "list"]
}
path "${OPENBAO_KV_MOUNT}/metadata/" {
  capabilities = ["list"]
}
EOF
)"
bao_api "sys/policies/acl/${POLICY}" -X PUT \
  -d "$(jq -n --arg p "$policy_hcl" '{policy: $p}')" >/dev/null
```

- **`lookup-self` is required.** Dokploy uses it to validate the token. Provider tokens don't get OpenBao's `default` policy, so without this path Test Connection fails with `token validation failed (status 403)`.
- **Listing `metadata/`** lets Dokploy's autocomplete browse from the top of the mount. It reveals only other projects' *names*, never their secrets.

## 3. Provider token and Dokploy provider

First check whether the provider already exists. If it does, stop here: its token is masked in Dokploy, so there's nothing to compare against.

```bash
dokploy_api "$CP_IP" "vaultProvider.all" \
  | jq -r --arg n "$PROVIDER" 'first(.[] | select(.name == $n) | .vaultProviderId) // empty'
```

Issue a token from the `dokploy-provider` role. It's a periodic orphan (768h period) with only the project policy:

```bash
TOKEN="$(bao_api "auth/token/create/${OPENBAO_PROVIDER_ROLE}" -X POST \
  -d "$(jq -n --arg p "$POLICY" --arg n "$NAME" \
    '{policies: [$p], display_name: ("dokploy-" + $n), meta: {project: $n}}')" \
  | jq -er '.auth.client_token')"

config="$(jq -n --arg u "$OPENBAO_INTERNAL_URL" --arg t "$TOKEN" --arg m "$OPENBAO_KV_MOUNT" \
  '{providerType: "hashicorp", url: $u, token: $t, mount: $m}')"
```

Test the connection. The test runs from Dokploy's server, so it also proves Dokploy can reach `http://openbao:8200` over `dokploy-network`:

```bash
dokploy_api "$CP_IP" "vaultProvider.testConnection" -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n --argjson c "$config" '{config: $c}')"
```

Create the provider, assigned to this project only:

```bash
dokploy_api "$CP_IP" "vaultProvider.create" -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n --arg n "$PROVIDER" --argjson c "$config" --arg p "$PROJECT_ID" \
    '{name: $n, config: $c, assignments: [{projectId: $p}]}')" >/dev/null
unset TOKEN config
```

**If the test or the create fails**, revoke the token so it isn't left live and orphaned:

```bash
bao_api "auth/token/revoke" -X POST -d @<(jq -n --arg t "$TOKEN" '{token: $t}') >/dev/null
```

## 4. Store secrets and reference them in the app

Put secrets under `secret/<name>/...`, either in the OpenBao UI at `http://<CP_IP>:8200/ui` (log in with the root token from `.openbao-init.json`) or through the API:

```bash
bao_api "${OPENBAO_KV_MOUNT}/data/${NAME}/app" -X POST \
  -d "$(jq -n --arg v 'the-password' '{data: {DB_PASSWORD: $v}}')" >/dev/null
```

Then, in any env editor inside the project:

```
DB_PASSWORD=${{vault.bao-<name>.<name>/app:DB_PASSWORD}}
```

Dokploy resolves the reference at deploy time, so **changing a secret only takes effect after a redeploy**.

## Things to know

- **The provider token expires 32 days after it was issued**, counted in real time, including while the cluster is off. Nothing renews it. After that, running containers keep working, but any deploy that resolves `${{vault.bao-<name>...}}` fails. To fix it, issue a new token (step 3) and replace the token on the existing `bao-<name>` provider in Dokploy.
- **Resolved values aren't only in OpenBao.** They end up in `/etc/dokploy/compose/<app>/code/.env` on the control plane and in the Swarm service spec. See DESIGN.md "Where values do end up".
