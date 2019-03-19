# This file contains all the interactions with Google Cloud
provider "google" {
  region = "${var.region}"
}

provider "google-beta" {
  region = "${var.region}"
}

# Generate a random id for the project - GCP projects must have globally
# unique names
resource "random_id" "random" {
  prefix      = "${var.project_prefix}"
  byte_length = "8"
}

# Create the project
resource "google_project" "vault" {
  name            = "${random_id.random.hex}"
  project_id      = "${random_id.random.hex}"
  folder_id       = "${var.folder_id}"
  billing_account = "${var.billing_account}"
}

# Create the vault service account
resource "google_service_account" "vault-server" {
  account_id   = "vault-server"
  display_name = "Vault Server"
  project      = "${google_project.vault.project_id}"
}

# Create a service account key
resource "google_service_account_key" "vault" {
  service_account_id = "${google_service_account.vault-server.name}"
}

# Add the service account to the project
resource "google_project_iam_member" "service-account" {
  count   = "${length(var.service_account_iam_roles)}"
  project = "${google_project.vault.project_id}"
  role    = "${element(var.service_account_iam_roles, count.index)}"
  member  = "serviceAccount:${google_service_account.vault-server.email}"
}

# Add user-specified roles
resource "google_project_iam_member" "service-account-custom" {
  count   = "${length(var.service_account_custom_iam_roles)}"
  project = "${google_project.vault.project_id}"
  role    = "${element(var.service_account_custom_iam_roles, count.index)}"
  member  = "serviceAccount:${google_service_account.vault-server.email}"
}

# Enable required services on the project
resource "google_project_service" "service" {
  count   = "${length(var.project_services)}"
  project = "${google_project.vault.project_id}"
  service = "${element(var.project_services, count.index)}"

  # Do not disable the service on destroy. On destroy, we are going to
  # destroy the project, but we need the APIs available to destroy the
  # underlying resources.
  disable_on_destroy = false
}

# Create the storage bucket
resource "google_storage_bucket" "vault" {
  name          = "${google_project.vault.project_id}-vault-storage"
  project       = "${google_project.vault.project_id}"
  force_destroy = true
  storage_class = "MULTI_REGIONAL"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      num_newer_versions = 1
    }
  }

  depends_on = ["google_project_service.service"]
}

# Grant service account access to the storage bucket
resource "google_storage_bucket_iam_member" "vault-server" {
  count  = "${length(var.storage_bucket_roles)}"
  bucket = "${google_storage_bucket.vault.name}"
  role   = "${element(var.storage_bucket_roles, count.index)}"
  member = "serviceAccount:${google_service_account.vault-server.email}"
}

# Create DNS Zone and extend vault-server iam to dns.admin role
data "google_dns_managed_zone" "dns_top_zone" {
  name    = "${var.dns_top_zone_name}"
  project = "${var.dns_top_zone_project}"
}

data "template_file" "project_dns_suffix" {
  template = "${replace( format("%s.%s", random_id.random.hex, data.google_dns_managed_zone.dns_top_zone.dns_name),"/^(.*)\\./","$1" )}"
}

resource "google_dns_managed_zone" "dns" {
  depends_on = ["google_project_service.service"]

  name        = "${random_id.random.hex}"
  dns_name    = "${data.template_file.project_dns_suffix.rendered}."
  description = "Project DNS zone"
  project     = "${google_project.vault.project_id}"
}

resource "google_dns_record_set" "delegation" {
  name         = "${google_dns_managed_zone.dns.dns_name}"
  managed_zone = "${data.google_dns_managed_zone.dns_top_zone.name}"
  project      = "${data.google_dns_managed_zone.dns_top_zone.project}"
  type         = "NS"
  ttl          = 300

  rrdatas = [
    "${google_dns_managed_zone.dns.name_servers}",
  ]
}

resource "google_project_iam_member" "service-account-dnsadmin" {
  project = "${google_project.vault.project_id}"
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.vault-server.email}"
}

# Create the KMS key ring
resource "google_kms_key_ring" "vault" {
  name     = "vault"
  location = "${var.region}"
  project  = "${google_project.vault.project_id}"

  depends_on = ["google_project_service.service"]
}

# Create the crypto key for encrypting init keys
resource "google_kms_crypto_key" "vault-init" {
  name            = "vault-init"
  key_ring        = "${google_kms_key_ring.vault.id}"
  rotation_period = "604800s"
}

# Create a custom IAM role with the most minimal set of permissions for the
# KMS auto-unsealer. Once hashicorp/vault#5999 is merged, this can be replaced
# with the built-in roles/cloudkms.cryptoKeyEncrypterDecryptor role.
resource "google_project_iam_custom_role" "vault-seal-kms" {
  project     = "${google_project.vault.project_id}"
  role_id     = "kmsEncrypterDecryptorViewer"
  title       = "KMS Encrypter Decryptor Viewer"
  description = "KMS crypto key permissions to encrypt, decrypt, and view key data"

  permissions = [
    "cloudkms.cryptoKeyVersions.useToEncrypt",
    "cloudkms.cryptoKeyVersions.useToDecrypt",

    # This is required until hashicorp/vault#5999 is merged. The auto-unsealer
    # attempts to read the key, which requires this additional permission.
    "cloudkms.cryptoKeys.get",
  ]
}

# Grant service account access to the key
resource "google_kms_crypto_key_iam_member" "vault-init" {
  crypto_key_id = "${google_kms_crypto_key.vault-init.id}"
  role          = "projects/${google_project.vault.project_id}/roles/${google_project_iam_custom_role.vault-seal-kms.role_id}"
  member        = "serviceAccount:${google_service_account.vault-server.email}"
}

# Create an external NAT IP
resource "google_compute_address" "vault-nat" {
  count   = 2
  name    = "vault-nat-external-${count.index}"
  project = "${google_project.vault.project_id}"
  region  = "${var.region}"

  depends_on = [
    "google_project_service.service",
  ]
}

# Create a network for GKE
resource "google_compute_network" "vault-network" {
  name                    = "vault-network"
  project                 = "${google_project.vault.project_id}"
  auto_create_subnetworks = false

  depends_on = [
    "google_project_service.service",
  ]
}

# Create subnets
resource "google_compute_subnetwork" "vault-subnetwork" {
  name          = "vault-subnetwork"
  project       = "${google_project.vault.project_id}"
  network       = "${google_compute_network.vault-network.self_link}"
  region        = "${var.region}"
  ip_cidr_range = "${var.kubernetes_network_ipv4_cidr}"

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "vault-pods"
    ip_cidr_range = "${var.kubernetes_pods_ipv4_cidr}"
  }

  secondary_ip_range {
    range_name    = "vault-svcs"
    ip_cidr_range = "${var.kubernetes_services_ipv4_cidr}"
  }
}

# Create a NAT router so the nodes can reach DockerHub, etc
resource "google_compute_router" "vault-router" {
  name    = "vault-router"
  project = "${google_project.vault.project_id}"
  region  = "${var.region}"
  network = "${google_compute_network.vault-network.self_link}"

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "vault-nat" {
  name    = "vault-nat-1"
  project = "${google_project.vault.project_id}"
  router  = "${google_compute_router.vault-router.name}"
  region  = "${var.region}"

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = ["${google_compute_address.vault-nat.*.self_link}"]

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = "${google_compute_subnetwork.vault-subnetwork.self_link}"
    source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE", "LIST_OF_SECONDARY_IP_RANGES"]

    secondary_ip_range_names = [
      "${google_compute_subnetwork.vault-subnetwork.secondary_ip_range.0.range_name}",
      "${google_compute_subnetwork.vault-subnetwork.secondary_ip_range.1.range_name}",
    ]
  }
}

# Get latest cluster version
data "google_container_engine_versions" "versions" {
  project = "${google_project.vault.project_id}"
  region  = "${var.region}"
}

# Create the GKE cluster
resource "google_container_cluster" "vault" {
  provider = "google-beta"

  name    = "vault"
  project = "${google_project.vault.project_id}"
  region  = "${var.region}"

  network    = "${google_compute_network.vault-network.self_link}"
  subnetwork = "${google_compute_subnetwork.vault-subnetwork.self_link}"

  initial_node_count = "${var.kubernetes_nodes_per_zone}"

  min_master_version = "${data.google_container_engine_versions.versions.latest_master_version}"
  node_version       = "${data.google_container_engine_versions.versions.latest_node_version}"

  logging_service    = "${var.kubernetes_logging_service}"
  monitoring_service = "${var.kubernetes_monitoring_service}"

  # Disable legacy ACLs. The default is false, but explicitly marking it false
  # here as well.
  enable_legacy_abac = false

  node_config {
    machine_type    = "${var.kubernetes_instance_type}"
    service_account = "${google_service_account.vault-server.email}"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    # Set metadata on the VM to supply more entropy
    metadata {
      google-compute-enable-virtio-rng = "true"
      disable-legacy-endpoints         = "true"
    }

    labels {
      service = "vault"
    }

    tags = ["vault"]

    # Protect node metadata
    workload_metadata_config {
      node_metadata = "SECURE"
    }
  }

  # Configure various addons
  addons_config {
    # Disable the Kubernetes dashboard, which is often an attack vector. The
    # cluster can still be managed via the GKE UI.
    kubernetes_dashboard {
      disabled = true
    }

    # Enable network policy configurations (like Calico).
    network_policy_config {
      disabled = false
    }
  }

  # Disable basic authentication and cert-based authentication.
  master_auth {
    username = ""
    password = ""

    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Enable network policy configurations (like Calico) - for some reason this
  # has to be in here twice.
  network_policy {
    provider = "CALICO"
    enabled  = true
  }

  # placeholder
  #pod_security_policy_config {
  #  enabled = true
  #}

  # Set the maintenance window.
  maintenance_policy {
    daily_maintenance_window {
      start_time = "${var.kubernetes_daily_maintenance_window}"
    }
  }
  # Allocate IPs in our subnetwork
  ip_allocation_policy {
    cluster_secondary_range_name  = "${google_compute_subnetwork.vault-subnetwork.secondary_ip_range.0.range_name}"
    services_secondary_range_name = "${google_compute_subnetwork.vault-subnetwork.secondary_ip_range.1.range_name}"
  }
  # Specify the list of CIDRs which can access the master's API
  master_authorized_networks_config {
    cidr_blocks = ["${var.kubernetes_master_authorized_networks}"]
  }
  # Configure the cluster to be private (not have public facing IPs)
  private_cluster_config {
    # This field is misleading. This prevents access to the master API from
    # any external IP. While that might represent the most secure
    # configuration, it is not ideal for most setups. As such, we disable the
    # private endpoint (allow the public endpoint) and restrict which CIDRs
    # can talk to that endpoint.
    enable_private_endpoint = false

    enable_private_nodes   = true
    master_ipv4_cidr_block = "${var.kubernetes_masters_ipv4_cidr}"
  }
  depends_on = [
    "google_project_service.service",
    "google_kms_crypto_key_iam_member.vault-init",
    "google_storage_bucket_iam_member.vault-server",
    "google_project_iam_member.service-account",
    "google_project_iam_member.service-account-custom",
    "google_compute_router_nat.vault-nat",
  ]
}

# Provision IP
resource "google_compute_address" "vault" {
  name    = "vault-lb"
  region  = "${var.region}"
  project = "${google_project.vault.project_id}"

  depends_on = ["google_project_service.service"]
}

## Exclude some known verbose logging"
resource "google_logging_project_exclusion" "vault-init" {
  name        = "vault-init-logs-exclusion"
  description = "Exclude vault-init container logging"
  project     = "${google_project.vault.project_id}"

  filter = "resource.type=\"k8s_container\" AND resource.labels.container_name=\"vault-init\" AND textPayload: (\"Next check in 10s\" OR \"Vault is initialized and unsealed\" OR \"Vault is unsealed and in standby mode\")"
}

resource "google_logging_project_exclusion" "bank-vaults" {
  name        = "bank-vaults-logs-exclusion"
  description = "Exclude bank-vaults container logging"
  project     = "${google_project.vault.project_id}"

  filter = "resource.type=\"k8s_container\" AND resource.labels.container_name=\"bank-vaults\" AND textPayload: (\"checking if vault is\" OR \"unexpected status code: 429\")"
}

output "address" {
  value = "${google_compute_address.vault.address}"
}

output "project" {
  value = "${google_project.vault.project_id}"
}

output "region" {
  value = "${var.region}"
}

output "kms_region" {
  value = "${google_kms_key_ring.vault.location}"
}

output "kms_key_ring" {
  value = "${google_kms_key_ring.vault.name}"
}

output "kms_crypto_key" {
  value = "${google_kms_crypto_key.vault-init.name}"
}

output "gcs_bucket_name" {
  value = "${google_storage_bucket.vault.name}"
}
