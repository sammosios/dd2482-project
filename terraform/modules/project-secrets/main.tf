# A Dokploy project's own secrets provider (APP-PROJECT-SETUP.md): an
# OpenBao policy that can read only secret/<project>/*, a token issued with
# just that policy, and a Dokploy provider "bao-<project>" holding it,
# assigned to that project only. Two independent fences: Dokploy won't
# resolve bao-<project> from another project, and the token can't read
# another project's secrets anyway.
terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
    dokploy = {
      source = "vanillauys/dokploy"
    }
  }
}

variable "project" {
  description = "Dokploy project name; also the path under secret/ its secrets live in."
  type        = string
}

variable "project_id" {
  description = "Dokploy project id."
  type        = string
}

variable "openbao_url" {
  description = "Where Dokploy's server reaches OpenBao."
  type        = string
}

variable "token_role" {
  description = "Token role the provider's token is issued from (terraform/services)."
  type        = string
}

locals {
  mount = "secret"
}

# Dokploy's Test Connection validates the token with lookup-self, which
# usually comes from the default policy; the role leaves that out, so it's
# granted here alone. Listing the mount root lets the editor's autocomplete
# start from the top, at the cost of showing every project's name.
resource "vault_policy" "project" {
  name   = "dokploy-project-${var.project}"
  policy = <<-EOT
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
    path "${local.mount}/data/${var.project}/*" {
      capabilities = ["read"]
    }
    path "${local.mount}/metadata/${var.project}/*" {
      capabilities = ["read", "list"]
    }
    path "${local.mount}/metadata/" {
      capabilities = ["list"]
    }
  EOT
}

# Dokploy stores the token and never renews it: it's periodic (768h, from
# the role), and every apply within 14 days of expiry renews it. The
# (deprecated) resource rather than the ephemeral one: an ephemeral token
# would be a new one on every apply, and Dokploy would need updating each time.
resource "vault_token" "project" {
  role_name         = var.token_role
  policies          = [vault_policy.project.name]
  display_name      = "dokploy-${var.project}"
  metadata          = { project = var.project }
  renewable         = true
  renew_min_lease   = 14 * 24 * 3600
  renew_increment   = 768 * 3600
  no_default_policy = true
}

resource "dokploy_vault_provider" "project" {
  name = "bao-${var.project}"
  hashicorp = {
    url   = var.openbao_url
    token = vault_token.project.client_token
    mount = local.mount
  }
  assignments = [{ project_id = var.project_id }]
  # The test runs from Dokploy's server, so it also proves Dokploy reaches
  # OpenBao over dokploy-network.
  verify_connection = true
}

output "provider_name" {
  value = dokploy_vault_provider.project.name
}

# A reference to secret/<project>/<path>:<field> for a service's env, which
# Dokploy resolves each time it deploys.
output "ref_prefix" {
  value = "vault.${dokploy_vault_provider.project.name}.${var.project}"
}
