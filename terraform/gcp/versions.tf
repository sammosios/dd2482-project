terraform {
  required_version = ">= 1.5"

  # The bucket is created by terraform/bootstrap. Every stage keeps its state
  # there, under its own prefix, and the later stages read this one's.
  backend "gcs" {
    bucket = "devops-project-510215-tfstate"
    prefix = "gcp"
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
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Credentials come from Application Default Credentials:
# `gcloud auth application-default login`.
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# The token needs Zone > DNS > Edit on var.cloudflare_zone_id, nothing else.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
