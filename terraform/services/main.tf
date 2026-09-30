# --- OpenBao: the KV mount, and the token role providers are issued from --------

# Dokploy's providers read from "secret", its default mount.
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "Secrets Dokploy resolves at deploy time, one path per project"
}

# Provider tokens are periodic orphans (they survive whatever token issued
# them), without the default policy, and can only get per-project policies,
# never root.
resource "vault_token_auth_backend_role" "dokploy_provider" {
  role_name               = "dokploy-provider"
  allowed_policies_glob   = ["dokploy-project-*"]
  orphan                  = true
  renewable               = true
  token_period            = 768 * 3600
  token_no_default_policy = true
  token_type              = "service"
}

module "infrastructure_secrets" {
  source = "../modules/project-secrets"

  project     = "infrastructure"
  project_id  = local.platform.infrastructure_project_id
  openbao_url = local.platform.openbao_internal_url
  token_role  = vault_token_auth_backend_role.dokploy_provider.role_name

  depends_on = [vault_mount.secret]
}

# --- CI runners ------------------------------------------------------------------
# Self-hosted GitHub Actions runners, one per worker (Swarm global mode on
# the workers), ephemeral: one job per container, then Swarm starts a clean
# one that registers again with the token. See DESIGN.md "CI runners".

resource "vault_kv_secret_v2" "github" {
  mount                = vault_mount.secret.path
  name                 = "infrastructure/github"
  data_json_wo         = jsonencode({ runner_pat = var.github_runner_pat })
  data_json_wo_version = var.github_runner_pat_version
}

resource "dokploy_compose" "github_runner" {
  name           = "github-runner"
  description    = "Self-hosted GitHub Actions runners, one per worker"
  environment_id = local.platform.infrastructure_environment_id
  compose_type   = "stack"

  # Resolved by Dokploy from OpenBao at deploy time: only this reference is
  # stored in Dokploy. Its value lands in the stack's .env on the control
  # plane and in the service's spec (DESIGN.md "Where values do end up").
  env = "GITHUB_PAT=$${{${module.infrastructure_secrets.ref_prefix}/github:runner_pat}}"

  raw = {
    compose_file = yamlencode({
      services = {
        runner = {
          # Pinned; the runner inside still self-updates when GitHub
          # requires it.
          image = "myoung34/github-runner:2.337.0-ubuntu-noble"
          environment = {
            # The image's entrypoint un-exports it, so jobs never see it.
            ACCESS_TOKEN       = "$${GITHUB_PAT}"
            RUNNER_SCOPE       = "repo"
            REPO_URL           = "https://github.com/${var.github_repo}"
            RUNNER_NAME_PREFIX = "dokploy"
            LABELS             = var.runner_labels
            # One job per container: the runner deregisters after its job,
            # the container exits, Swarm starts a fresh one.
            EPHEMERAL = "true"
          }
          # Jobs build and push images with the node's own Docker daemon:
          # root on that node for anything a workflow runs. Fine for our own
          # repo's workflows, not for untrusted pull requests.
          volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
          deploy = {
            # One runner per worker: adding a worker adds a runner, and CI
            # load stays off the control plane.
            mode = "global"
            placement = {
              constraints = ["node.role == worker"]
            }
            restart_policy = { condition = "any" }
          }
        }
      }
    })
  }

  depends_on = [vault_kv_secret_v2.github]
}
