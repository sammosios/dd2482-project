output "infrastructure_project_id" {
  value = dokploy_project.infrastructure.id
}

output "infrastructure_environment_id" {
  value = local.env_id
}

output "registry" {
  value = {
    id       = dokploy_registry.cluster.id
    addr     = local.registry_addr
    username = local.registry_user
  }
}

output "registry_password" {
  value     = random_password.registry.result
  sensitive = true
}

output "openbao_url" {
  value = "https://${local.openbao_host}"
}

# Dokploy's server reaches OpenBao here, over dokploy-network.
output "openbao_internal_url" {
  value = "http://openbao:8200"
}
