variable "github_repo" {
  description = "owner/name of the repository the CI runners serve."
  type        = string
  default     = "sammosios/dd2482-project"
}

# A fine-grained token: resource owner the repo's owner, only this repository,
# Administration: Read and write (register runners), Metadata: Read-only,
# nothing else. Runners re-register with it after every job, so CI stops when
# it expires. Write-only: it goes to OpenBao and never into Terraform's
# state. Bump github_runner_pat_version when it changes.
variable "github_runner_pat" {
  description = "GitHub token the runners register with."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "github_runner_pat_version" {
  description = "Bump to send a new github_runner_pat to OpenBao."
  type        = number
  default     = 1
}

variable "runner_labels" {
  description = "Extra runner labels; workflows use runs-on: [self-hosted, <label>]."
  type        = string
  default     = "dokploy"
}
