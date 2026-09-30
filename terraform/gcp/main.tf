resource "google_project_service" "api" {
  for_each = toset(["compute.googleapis.com", "secretmanager.googleapis.com"])

  service            = each.key
  disable_on_destroy = false
}

# Swarm's overlay networks need an MTU of 1500 underneath. GCP's default VPC
# uses 1460, so the cluster gets its own network. GCP NATs a VM's public IP
# onto its private one, so the swarm runs over this network's addresses.
resource "google_compute_network" "cluster" {
  name                    = "${var.name_prefix}-net"
  auto_create_subnetworks = false
  mtu                     = 1500

  depends_on = [google_project_service.api]
}

resource "google_compute_subnetwork" "cluster" {
  name          = "${var.name_prefix}-subnet"
  network       = google_compute_network.cluster.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/24"
}

# Workers join the swarm at this address, so it's fixed before any VM
# exists, and reserved: an address that's only requested can be handed to a
# VM created first. Clear of the low addresses GCP hands out in order. The
# public one is fixed so DNS keeps pointing at the control plane.
resource "google_compute_address" "cp_internal" {
  name         = "${var.name_prefix}-cp-internal"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.cluster.id
  address      = cidrhost(google_compute_subnetwork.cluster.ip_cidr_range, 10)
}

locals {
  cp_private_ip = google_compute_address.cp_internal.address
}

resource "google_compute_address" "cp" {
  name   = "${var.name_prefix}-cp"
  region = var.region

  depends_on = [google_project_service.api]
}

# 80/443 to the control plane from anywhere (Traefik: the apps, and the
# Dokploy and OpenBao UIs), ssh to every node, and Swarm's ports only
# between the nodes. Each node's port guard closes Dokploy, the registry and
# OpenBao on top of this.
resource "google_compute_firewall" "ssh" {
  name          = "${var.name_prefix}-ssh"
  network       = google_compute_network.cluster.id
  source_ranges = var.ssh_source_ranges
  target_tags   = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "web" {
  name          = "${var.name_prefix}-web"
  network       = google_compute_network.cluster.id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-cp"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_firewall" "swarm" {
  name        = "${var.name_prefix}-swarm"
  network     = google_compute_network.cluster.id
  source_tags = ["${var.name_prefix}-node"]
  target_tags = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["2377", "7946"]
  }

  allow {
    protocol = "udp"
    ports    = ["7946", "4789"]
  }

  allow {
    protocol = "icmp"
  }
}

# Secrets passed between Terraform and the nodes, each readable (and
# writable) only by the service accounts that need it:
#   swarm-join-token     control plane writes, workers read
#   dokploy-admin        Terraform writes, control plane reads to create
#                        Dokploy's first admin (node/dokploy-bootstrap.py)
#   dokploy-api-key      control plane writes the key it mints, Terraform's
#                        later stages read it
#   openbao-password     Terraform writes, control plane hands it to
#                        OpenBao's self-initialization, the later stages log
#                        in to OpenBao with it
# Whoever runs Terraform is the project's owner and can read all of them.
locals {
  secrets = {
    swarm-join-token = { read = ["cp", "worker"], write = ["cp"] }
    dokploy-admin    = { read = ["cp"], write = [] }
    dokploy-api-key  = { read = ["cp"], write = ["cp"] }
    openbao-password = { read = ["cp"], write = [] }
  }
}

resource "google_secret_manager_secret" "node" {
  for_each = local.secrets

  secret_id = "${var.name_prefix}-${each.key}"

  replication {
    auto {}
  }

  depends_on = [google_project_service.api]
}

resource "google_service_account" "node" {
  for_each = toset(["cp", "worker"])

  account_id   = "${var.name_prefix}-${each.key}"
  display_name = "${var.name_prefix} ${each.key} nodes"
}

resource "google_secret_manager_secret_iam_member" "read" {
  for_each = merge([
    for secret, access in local.secrets : { for role in access.read : "${secret}/${role}" => { secret = secret, role = role } }
  ]...)

  secret_id = google_secret_manager_secret.node[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.node[each.value.role].member
}

resource "google_secret_manager_secret_iam_member" "write" {
  for_each = merge([
    for secret, access in local.secrets : { for role in access.write : "${secret}/${role}" => { secret = secret, role = role } }
  ]...)

  secret_id = google_secret_manager_secret.node[each.value.secret].id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = google_service_account.node[each.value.role].member
}

# Earlier names of the join token's secret and its access rules.
moved {
  from = google_secret_manager_secret.join_token
  to   = google_secret_manager_secret.node["swarm-join-token"]
}
moved {
  from = google_secret_manager_secret_iam_member.join_token_read["cp"]
  to   = google_secret_manager_secret_iam_member.read["swarm-join-token/cp"]
}
moved {
  from = google_secret_manager_secret_iam_member.join_token_read["worker"]
  to   = google_secret_manager_secret_iam_member.read["swarm-join-token/worker"]
}
moved {
  from = google_secret_manager_secret_iam_member.join_token_write
  to   = google_secret_manager_secret_iam_member.write["swarm-join-token/cp"]
}

resource "random_password" "dokploy_admin" {
  length = 32
}

resource "google_secret_manager_secret_version" "dokploy_admin" {
  secret = google_secret_manager_secret.node["dokploy-admin"].id
  secret_data = jsonencode({
    name     = var.dokploy_admin_name
    email    = var.dokploy_admin_email
    password = random_password.dokploy_admin.result
  })
}

resource "random_password" "openbao" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret_version" "openbao" {
  secret      = google_secret_manager_secret.node["openbao-password"].id
  secret_data = random_password.openbao.result
}

locals {
  ssh_keys = "${var.ssh_user}:${trimspace(var.ssh_public_key)}"

  # The shared part of every node's startup script, then its role's own.
  startup_common = templatefile("${path.module}/node/common.sh.tftpl", {
    port_guard        = trimspace(file("${path.module}/node/port-guard"))
    port_guard_unit   = trimspace(file("${path.module}/node/port-guard.service"))
    peers             = google_compute_subnetwork.cluster.ip_cidr_range
    docker_version    = var.docker_version
    join_token_secret = google_secret_manager_secret.node["swarm-join-token"].id
  })

  nodes = merge(
    {
      cp = {
        role         = "cp"
        machine_type = var.cp_machine_type
        disk_gb      = var.cp_disk_gb
        tags         = ["${var.name_prefix}-node", "${var.name_prefix}-cp"]
        private_ip   = local.cp_private_ip
        public_ip    = google_compute_address.cp.address
        startup = templatefile("${path.module}/node/cp.sh.tftpl", {
          dokploy_version         = var.dokploy_version
          cp_private_ip           = local.cp_private_ip
          dokploy_bootstrap       = trimspace(file("${path.module}/node/dokploy-bootstrap.py"))
          admin_secret            = google_secret_manager_secret.node["dokploy-admin"].id
          api_key_secret          = google_secret_manager_secret.node["dokploy-api-key"].id
          openbao_password_secret = google_secret_manager_secret.node["openbao-password"].id
          dokploy_host            = "dokploy.${var.domain}"
          acme_email              = var.acme_email
        })
      }
    },
    {
      for i in range(var.worker_count) : "worker-${i + 1}" => {
        role         = "worker"
        machine_type = var.worker_machine_type
        disk_gb      = var.worker_disk_gb
        tags         = ["${var.name_prefix}-node", "${var.name_prefix}-worker"]
        private_ip   = null
        public_ip    = null
        startup = templatefile("${path.module}/node/worker.sh.tftpl", {
          cp_private_ip = local.cp_private_ip
        })
      }
    }
  )
}

resource "google_compute_instance" "node" {
  for_each = local.nodes

  name         = "${var.name_prefix}-${each.key}"
  machine_type = each.value.machine_type
  zone         = var.zone
  tags         = each.value.tags

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = each.value.disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.cluster.id
    network_ip = each.value.private_ip

    # The control plane's static address; an ephemeral one for workers.
    access_config {
      nat_ip = each.value.public_ip
    }
  }

  service_account {
    email  = google_service_account.node[each.value.role].email
    scopes = ["cloud-platform"]
  }

  # Runs on every boot. A change reaches a running VM at its next boot;
  # the scripts only ever add what's missing.
  metadata = {
    ssh-keys       = local.ssh_keys
    startup-script = "${local.startup_common}\n${each.value.startup}"
  }

  # The startup scripts use their secrets from the moment they run.
  depends_on = [
    google_secret_manager_secret_iam_member.read,
    google_secret_manager_secret_iam_member.write,
    google_secret_manager_secret_version.dokploy_admin,
    google_secret_manager_secret_version.openbao,
  ]
}
