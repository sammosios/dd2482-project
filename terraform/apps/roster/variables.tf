variable "github_repo" {
  description = "owner/name of the repository whose CI deploys this app."
  type        = string
  default     = "sammosios/dd2482-project"
}

# Only used when the app is created: from then on CI decides which image
# runs (application.saveDockerProvider), and Terraform ignores it. up.sh
# passes the tag CI builds for the current main.
variable "image_tag" {
  description = "roster image tag the app is created with."
  type        = string
  default     = "latest"
}

# up.sh creates the app with deploy_app = false, since its image doesn't
# exist until CI has built it; CI then deploys it.
variable "deploy_app" {
  description = "Deploy the app when Terraform creates or changes it."
  type        = bool
  default     = true
}

variable "replicas" {
  type    = number
  default = 2
}
