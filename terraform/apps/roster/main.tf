# The example app (web-app/, "Roster") the way a Dokploy user runs one: an
# application from a prebuilt image, next to Dokploy's own PostgreSQL and
# Redis, with its secrets in OpenBao behind the project's own provider.
# Terraform owns how it runs; CI owns which image (DESIGN.md "Web app
# delivery").

locals {
  project = "roster"
  host    = "roster.${local.gcp.domain}"
}

resource "dokploy_project" "roster" {
  name        = local.project
  description = "Example web app"
}

locals {
  env_id = dokploy_project.roster.production_environment_id
}

# --- Database and Redis ------------------------------------------------------------
# Their passwords are generated here, so Terraform is their source of truth;
# OpenBao holds the URLs built from them.

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "dokploy_postgres" "db" {
  name              = "roster-db"
  app_name_prefix   = "roster-db"
  description       = "PostgreSQL for Roster"
  environment_id    = local.env_id
  docker_image      = "postgres:18"
  database_name     = "roster"
  database_user     = "roster"
  database_password = random_password.db.result
}

resource "dokploy_redis" "redis" {
  name              = "roster-redis"
  app_name_prefix   = "roster-redis"
  description       = "Redis for Roster's sign-in rate limiter"
  environment_id    = local.env_id
  docker_image      = "redis:8"
  database_password = random_password.redis.result
}

# --- Secrets ------------------------------------------------------------------------

module "secrets" {
  source = "../../modules/project-secrets"

  project     = local.project
  project_id  = dokploy_project.roster.id
  openbao_url = local.platform.openbao_internal_url
  token_role  = local.services.token_role
}

# The app's first admin. It reads ADMIN_* only on its first start, but
# they're credentials, so they go through OpenBao like the rest.
resource "random_password" "admin" {
  length  = 24
  special = false
}

locals {
  # Services reach each other by their app name over dokploy-network.
  app_secrets = {
    DATABASE_URL   = "postgresql://roster:${random_password.db.result}@${dokploy_postgres.db.app_name}:5432/roster"
    REDIS_URL      = "redis://default:${random_password.redis.result}@${dokploy_redis.redis.app_name}:6379"
    ADMIN_EMAIL    = local.gcp.dokploy_admin_email
    ADMIN_NAME     = local.gcp.dokploy_admin_name
    ADMIN_PASSWORD = random_password.admin.result
  }
}

resource "vault_kv_secret_v2" "app" {
  mount     = local.services.kv_mount
  name      = "${local.project}/app"
  data_json = jsonencode(local.app_secrets)
}

# --- The application ------------------------------------------------------------------

resource "dokploy_application" "app" {
  name             = "roster-app"
  app_name_prefix  = "roster-app"
  description      = "Roster, the example web app"
  environment_id   = local.env_id
  replicas         = var.replicas
  deploy_on_change = var.deploy_app

  docker = {
    image        = "${local.platform.registry.addr}/roster:${var.image_tag}"
    registry_url = local.platform.registry.addr
    username     = local.platform.registry.username
    password     = local.platform.registry_password
  }

  # Only references: Dokploy resolves them from OpenBao each time it
  # deploys. SECRETS_VERSION changes with every new version of the secret,
  # which makes this a change that redeploys the app with the new values.
  env = join("\n", concat(
    [for k in keys(local.app_secrets) : "${k}=$${{${module.secrets.ref_prefix}/app:${k}}}"],
    ["SECRETS_VERSION=${vault_kv_secret_v2.app.metadata.version}"],
  ))
  create_env_file = false

  lifecycle {
    # CI points the app at each new image (DESIGN.md "Web app delivery").
    ignore_changes = [docker]
  }
}

resource "dokploy_domain" "app" {
  application_id   = dokploy_application.app.id
  host             = local.host
  port             = 8080
  https            = true
  certificate_type = "letsencrypt"
}

# --- CI ----------------------------------------------------------------------------------
# What .github/workflows/web-app-ci.yml pushes and deploys with: its own
# Dokploy API key, and the registry's credentials.

resource "dokploy_api_key" "ci" {
  name               = "github-actions"
  prefix             = "ci"
  rate_limit_enabled = false
}

locals {
  ci_secrets = {
    DOKPLOY_API_KEY   = dokploy_api_key.ci.key
    REGISTRY_PASSWORD = local.platform.registry_password
  }
  ci_variables = {
    DOKPLOY_URL   = local.gcp.dokploy_url
    ROSTER_APP_ID = dokploy_application.app.id
    ROSTER_URL    = "https://${local.host}"
    REGISTRY_ADDR = local.platform.registry.addr
    REGISTRY_USER = local.platform.registry.username
  }
}

resource "github_actions_secret" "ci" {
  for_each = nonsensitive(toset(keys(local.ci_secrets)))

  repository      = split("/", var.github_repo)[1]
  secret_name     = each.key
  plaintext_value = local.ci_secrets[each.key]
}

resource "github_actions_variable" "ci" {
  for_each = local.ci_variables

  repository    = split("/", var.github_repo)[1]
  variable_name = each.key
  value         = each.value
}
