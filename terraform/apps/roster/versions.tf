terraform {
  required_version = ">= 1.11"

  backend "gcs" {
    bucket = "devops-project-510215-tfstate"
    prefix = "apps/roster"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "~> 1.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "devops-project-510215"
}

data "terraform_remote_state" "gcp" {
  backend = "gcs"
  config = {
    bucket = "devops-project-510215-tfstate"
    prefix = "gcp"
  }
}

data "terraform_remote_state" "services" {
  backend = "gcs"
  config = {
    bucket = "devops-project-510215-tfstate"
    prefix = "services"
  }
}

data "terraform_remote_state" "platform" {
  backend = "gcs"
  config = {
    bucket = "devops-project-510215-tfstate"
    prefix = "platform"
  }
}

locals {
  gcp      = data.terraform_remote_state.gcp.outputs
  platform = data.terraform_remote_state.platform.outputs
  services = data.terraform_remote_state.services.outputs
}

data "google_secret_manager_secret_version" "dokploy_api_key" {
  secret = local.gcp.dokploy_api_key_secret
}

data "google_secret_manager_secret_version" "openbao_password" {
  secret = local.gcp.openbao_password_secret
}

provider "dokploy" {
  endpoint = local.gcp.dokploy_url
  api_key  = data.google_secret_manager_secret_version.dokploy_api_key.secret_data
}

# Logs in as the user OpenBao's self-initialization created
# (terraform/platform), over bao.<domain>.
provider "vault" {
  address = local.platform.openbao_url
  auth_login_userpass {
    username = "terraform"
    password = data.google_secret_manager_secret_version.openbao_password.secret_data
  }
}

# Reads GITHUB_TOKEN (up.sh passes `gh auth token`): sets the Actions secrets
# and variables CI deploys with.
provider "github" {
  owner = split("/", var.github_repo)[0]
}
