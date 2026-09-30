locals {
  worker_ips = [for i in range(var.worker_count) : google_compute_instance.node["worker-${i + 1}"].network_interface[0].access_config[0].nat_ip]
}

output "cp_public_ip" {
  value = google_compute_address.cp.address
}

output "worker_public_ips" {
  value = local.worker_ips
}

output "hostnames" {
  description = "The names pointed at the control plane, by short name."
  value       = { for h in var.hostnames : h => "${h}.${var.domain}" }
}

output "domain" {
  value = var.domain
}

output "acme_email" {
  value = var.acme_email
}

output "dokploy_url" {
  value = "https://dokploy.${var.domain}"
}

output "dokploy_admin_email" {
  value = var.dokploy_admin_email
}

output "dokploy_admin_password" {
  value     = random_password.dokploy_admin.result
  sensitive = true
}

# Where the later stages read the Dokploy API key and OpenBao's password.
output "dokploy_api_key_secret" {
  value = google_secret_manager_secret.node["dokploy-api-key"].id
}

output "openbao_password_secret" {
  value = google_secret_manager_secret.node["openbao-password"].id
}

output "dokploy_admin_name" {
  value = var.dokploy_admin_name
}
