# The bucket every other stage keeps its Terraform state in. This stage's own
# state is local (terraform/bootstrap/terraform.tfstate, gitignored): it
# holds nothing secret, and if it's lost, `terraform import
# google_storage_bucket.tfstate devops-project-510215-tfstate` gets it back.
# up.sh applies it first.
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "devops-project-510215"
}

resource "google_storage_bucket" "tfstate" {
  name     = "devops-project-510215-tfstate"
  location = "EU"

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The states hold secrets (generated passwords, OpenBao tokens); old
  # versions let a broken state be rolled back.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  # down.sh never destroys this stage; deleting the bucket loses every state.
  lifecycle {
    prevent_destroy = true
  }
}
