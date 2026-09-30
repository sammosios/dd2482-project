locals {
  cp_ip      = google_compute_instance.node["cp"].network_interface[0].access_config[0].nat_ip
  worker_ips = [for i in range(var.worker_count) : google_compute_instance.node["worker-${i + 1}"].network_interface[0].access_config[0].nat_ip]
}

output "cp_public_ip" {
  value = local.cp_ip
}

output "worker_public_ips" {
  value = local.worker_ips
}

# `terraform output -raw hosts_env > ../../remote/hosts.env`
output "hosts_env" {
  value = <<-EOT
    CP_HOST="${local.cp_ip}"
    WORKER_HOSTS="${join(" ", local.worker_ips)}"
    SSH_USER="${var.ssh_user}"
  EOT
}
