terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
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
