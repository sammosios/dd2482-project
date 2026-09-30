terraform {
  required_version = ">= 1.5"

  backend "gcs" {
    bucket = "devops-project-510215-tfstate"
    prefix = "platform"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.7"
    }
  }
}

provider "google" {
  project = "devops-project-510215"
}

# What terraform/gcp set up: the domain, and the secrets the control plane
# filled in while it booted.
data "terraform_remote_state" "gcp" {
  backend = "gcs"
  config = {
    bucket = "devops-project-510215-tfstate"
    prefix = "gcp"
  }
}

locals {
  gcp = data.terraform_remote_state.gcp.outputs
}

# Minted by the control plane on its first boot (node/dokploy-bootstrap.py).
data "google_secret_manager_secret_version" "dokploy_api_key" {
  secret = local.gcp.dokploy_api_key_secret
}

provider "dokploy" {
  endpoint = local.gcp.dokploy_url
  api_key  = data.google_secret_manager_secret_version.dokploy_api_key.secret_data
}
