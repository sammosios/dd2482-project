output "token_role" {
  value = vault_token_auth_backend_role.dokploy_provider.role_name
}

output "kv_mount" {
  value = vault_mount.secret.path
}

output "github_repo" {
  value = var.github_repo
}
