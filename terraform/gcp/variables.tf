variable "project_id" {
  description = "GCP project to create the cluster in."
  type        = string
  default     = "devops-project-510215"
}

# Finland: the closest region to Stockholm (europe-north2) with capacity
# when that one hit a stockout. Any region works; move zone with it.
variable "region" {
  description = "Region for the subnet."
  type        = string
  default     = "europe-north1"
}

variable "zone" {
  description = "Zone for the VMs; must be in var.region."
  type        = string
  default     = "europe-north1-a"
}

variable "name_prefix" {
  description = "Prefix for every resource's name."
  type        = string
  default     = "dokploy"
}

variable "worker_count" {
  description = "Number of worker VMs."
  type        = number
  default     = 2
}

# The minimums from remote/hosts.env.example: control plane 2 vCPUs, 4 GB,
# 30 GB; workers 2 vCPUs, 2 GB, 15 GB.
variable "cp_machine_type" {
  description = "Control plane machine type (e2-medium: 2 vCPUs, 4 GB)."
  type        = string
  default     = "e2-medium"
}

variable "cp_disk_gb" {
  description = "Control plane boot disk size in GB."
  type        = number
  default     = 30
}

variable "worker_machine_type" {
  description = "Worker machine type (e2-small: 2 vCPUs, 2 GB)."
  type        = string
  default     = "e2-small"
}

variable "worker_disk_gb" {
  description = "Worker boot disk size in GB."
  type        = number
  default     = 15
}

variable "ssh_user" {
  description = "User created on every VM with the ssh key below; gets passwordless sudo."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "Public key installed for var.ssh_user, e.g. \"ssh-ed25519 AAAA... you@host\"."
  type        = string
}

# Open to the internet by default, since the operator's address changes.
# Ubuntu's cloud images only take key logins; narrow this to a /32 when the
# address is stable.
variable "ssh_source_ranges" {
  description = "CIDRs allowed to ssh to the nodes."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "domain" {
  description = "Cloudflare zone the cluster's hostnames go in."
  type        = string
  default     = "sammosios.com"
}

variable "cloudflare_zone_id" {
  description = "Id of var.domain's zone, from its Overview page in the Cloudflare dashboard."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone > DNS > Edit on var.cloudflare_zone_id."
  type        = string
  sensitive   = true
}

# DNS only, not proxied through Cloudflare: Traefik on the control plane
# answers Let's Encrypt's HTTP challenge and terminates TLS itself.
variable "hostnames" {
  description = "Names under var.domain pointed at the control plane: Dokploy's UI, OpenBao's UI and the apps."
  type        = list(string)
  default     = ["dokploy", "bao", "roster"]
}

# The version terraform-provider-dokploy targets (see its README); move them
# together.
variable "dokploy_version" {
  description = "Dokploy release the control plane installs."
  type        = string
  default     = "v0.30.7"
}

# What Dokploy's installer would install itself; every node gets this one.
variable "docker_version" {
  description = "Docker Engine version on every node."
  type        = string
  default     = "28.5.0"
}

variable "dokploy_admin_name" {
  description = "Name of Dokploy's first admin. Its password is generated: terraform output -raw dokploy_admin_password."
  type        = string
}

variable "dokploy_admin_email" {
  description = "Email (the login) of Dokploy's first admin."
  type        = string
}

variable "acme_email" {
  description = "Email Let's Encrypt sends certificate expiry notices to."
  type        = string
  default     = "sam.mosios+letsencrypt@gmail.com"
}
