# Giving an app project its own OpenBao secrets provider

Every Dokploy project that reads secrets from OpenBao gets its own provider, so no project can read another's secrets (DESIGN.md "Secrets: OpenBao"). The [`project-secrets`](./terraform/modules/project-secrets) module sets one up: an OpenBao policy that reads only `secret/<name>/*`, a token issued with just that policy from the `dokploy-provider` role, and a Dokploy provider `bao-<name>` holding it, assigned to that project only. [`terraform/apps/roster`](./terraform/apps/roster) is the complete example; copy it as a new stage, `terraform/apps/<name>`.

## 1. The project and its provider

```hcl
resource "dokploy_project" "app" {
  name = "myapp"
}

module "secrets" {
  source = "../../modules/project-secrets"

  project     = dokploy_project.app.name
  project_id  = dokploy_project.app.id
  openbao_url = local.platform.openbao_internal_url
  token_role  = local.services.token_role
}
```

The provider tests its connection when it's created. The test runs from Dokploy's server, so it also proves Dokploy reaches `http://openbao:8200` over `dokploy-network`.

## 2. The secrets

Under `secret/<name>/`, written by Terraform:

```hcl
resource "vault_kv_secret_v2" "app" {
  mount     = local.services.kv_mount
  name      = "myapp/app"
  data_json = jsonencode({ DB_PASSWORD = random_password.db.result })
}
```

For a value that must not land in Terraform's state (a token you're given, not one Terraform generates), use `data_json_wo` with an `ephemeral` variable and bump `data_json_wo_version` when it changes, as `terraform/services` does for the runners' GitHub token. Values can also be set by hand in the OpenBao UI at `https://bao.<domain>/ui`, but the next apply puts Terraform's back.

## 3. Reference them in the app

In the application's or compose resource's `env`, one reference per value. `$${` is Terraform's escape for a literal `${`:

```hcl
env = join("\n", [
  "DB_PASSWORD=$${{${module.secrets.ref_prefix}/app:DB_PASSWORD}}",
  "SECRETS_VERSION=${vault_kv_secret_v2.app.metadata.version}",
])
```

Dokploy resolves the reference at deploy time, so **a changed secret only takes effect after a redeploy**. `SECRETS_VERSION` handles that: a new version of the secret changes the env, and the provider redeploys the service.

## Things to know

- **The provider token expires 32 days after it was last renewed**, counted in real time, including while the cluster is off. Any `terraform apply` of the stage within 14 days of expiry renews it; `./up.sh` applies every stage. After it expires, running containers keep working, but any deploy that resolves `${{vault.bao-<name>...}}` fails until the next apply.
- **Resolved values aren't only in OpenBao.** They end up in `/etc/dokploy/compose/<app>/code/.env` on the control plane and in the Swarm service spec. See DESIGN.md "Where values do end up".
- **Dokploy won't resolve another project's provider:** a reference to `bao-roster` from any project but `roster` fails, even if the path exists.
