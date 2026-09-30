# Swarm's overlay networks need an MTU of 1500 underneath, and the remote
# chain refuses anything smaller (remote/lib/prepare.sh). GCP's default VPC
# uses 1460, so the cluster gets its own network. GCP NATs a VM's public IP
# onto its private one, so the swarm runs over this network's addresses.
resource "google_compute_network" "cluster" {
  name                    = "${var.name_prefix}-net"
  auto_create_subnetworks = false
  mtu                     = 1500
}

resource "google_compute_subnetwork" "cluster" {
  name          = "${var.name_prefix}-subnet"
  network       = google_compute_network.cluster.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/24"
}

# The provider's firewall, as remote/hosts.env.example asks for it. Each
# node's port guard closes Dokploy, the registry and OpenBao on top of this.
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

locals {
  ssh_keys = "${var.ssh_user}:${trimspace(var.ssh_public_key)}"

  nodes = merge(
    {
      cp = {
        machine_type = var.cp_machine_type
        disk_gb      = var.cp_disk_gb
        tags         = ["${var.name_prefix}-node", "${var.name_prefix}-cp"]
      }
    },
    {
      for i in range(var.worker_count) : "worker-${i + 1}" => {
        machine_type = var.worker_machine_type
        disk_gb      = var.worker_disk_gb
        tags         = ["${var.name_prefix}-node", "${var.name_prefix}-worker"]
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

    # Ephemeral public IP.
    access_config {}
  }

  metadata = {
    ssh-keys = local.ssh_keys
  }
}
