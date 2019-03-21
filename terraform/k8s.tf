# Query the client configuration for our current service account, which shoudl
# have permission to talk to the GKE cluster since it created it.
data "google_client_config" "current" {}

# This file contains all the interactions with Kubernetes
provider "kubernetes" {
  load_config_file = false
  host             = "${google_container_cluster.vault.endpoint}"

  cluster_ca_certificate = "${base64decode(google_container_cluster.vault.master_auth.0.cluster_ca_certificate)}"
  token                  = "${data.google_client_config.current.access_token}"
}

module "flux_bootstrap" {
  source                       = "./flux"
  flux_repo_git_poll_interval  = "1m"
  flux_repo_git_url            = "git@gitlab.com:mintel/satoshi/experimental/gitops-rendered-manifests.git"
  flux_repo_git_paths          = ["bootstrap/common", "bootstrap/dev"]
  flux_repo_git_branch         = "dev"
  flux_repo_git_label          = "flux-sync-dev"
  flux_sync_interval           = "1m"
  flux_sync_garbage_collection = "true"
  flux_ssh_private_key         = "${file("${path.module}/flux.key")}"
  flux_instance                = "bootstrap"
  disable_registry_scan        = "true"

  dependencies = []
}
