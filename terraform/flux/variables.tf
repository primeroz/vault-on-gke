variable "memcached_version" {
  default = "1.4.25"

  description = <<EOF
Namespace where to deploy all vault resources
EOF
}

variable "kubernetes_flux_version" {
  default = "1.11.0"

  description = <<EOF
FLUXD Version
EOF
}

variable "flux_repo_git_poll_interval" {
  default = "5m"

  description = <<EOF
period at which to fetch any new commits from the git repo
EOF
}

variable "flux_repo_git_url" {
  description = <<EOF
URL of git repo with Kubernetes manifests; e.g., git@github.com:weaveworks/flux-get-started
EOF
}

variable "flux_repo_git_paths" {
  type    = "list"
  default = ["/"]

  description = <<EOF
paths within git repo to locate Kubernetes manifests (relative path)
EOF
}

variable "flux_repo_git_branch" {
  default = "master"

  description = <<EOF
branch of git repo to use for Kubernetes manifests
EOF
}

variable "flux_repo_git_label" {
  default = "flux-sync"

  description = <<EOF
label to keep track of sync progress; overrides both --git-sync-tag and --git-notes-ref
EOF
}

variable "flux_sync_interval" {
  default = "5m"

  description = <<EOF
apply the git config to the cluster at least this often. New commits may provoke more frequent syncs
EOF
}

variable "flux_sync_garbage_collection" {
  default = "false"

  description = <<EOF
experimental: when set, fluxd will delete resources that it created, but are no longer present in git
EOF
}

variable "flux_ssh_private_key" {
  description = <<EOF
Key to use for ssh access to the repo
EOF
}

variable "flux_instance" {
  default = "main"

  description = <<EOF
instance of flux
EOF
}

variable "dependencies" {
  type = "list"
}

variable "disable_registry_scan" {
  default     = "false"
  description = "disable scanning of images for this flux instance"
}

variable "wait_seconds_at_start" {
  default     = "60"
  description = "Wait for X seconds at the start of the module"
}
