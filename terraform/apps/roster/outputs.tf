output "url" {
  value = "https://${local.host}"
}

output "app_id" {
  value = dokploy_application.app.id
}

output "admin_email" {
  value = local.app_secrets.ADMIN_EMAIL
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
