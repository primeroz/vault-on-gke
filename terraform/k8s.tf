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

# Create the namespace
resource "kubernetes_namespace" "flux" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    annotations {
      name = "${var.kubernetes_namespace_flux}"
    }

    labels {
      scope = "${var.kubernetes_namespace_flux}"
    }

    name = "${var.kubernetes_namespace_flux}"
  }
}

resource "kubernetes_namespace" "vault" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    annotations {
      name = "${var.kubernetes_namespace_vault}"
    }

    labels {
      scope = "${var.kubernetes_namespace_vault}"
    }

    name = "${var.kubernetes_namespace_vault}"
  }
}

# Write the vault secret
resource "kubernetes_secret" "vault-tls" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "vault-tls"
    namespace = "${kubernetes_namespace.vault.metadata.0.name}"
  }

  data {
    "vault.crt" = "${tls_locally_signed_cert.vault.cert_pem}\n${tls_self_signed_cert.vault-ca.cert_pem}"
    "vault.key" = "${tls_private_key.vault.private_key_pem}"
    "ca.crt"    = "${tls_self_signed_cert.vault-ca.cert_pem}"
  }
}

# Flux deployment
resource "kubernetes_service_account" "flux" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "flux"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels {
      name = "flux"
      app  = "flux"
    }
  }
}

resource "kubernetes_cluster_role" "flux" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name = "flux"

    labels {
      name = "flux"
      app  = "flux"
    }
  }

  rule = [
    {
      api_groups = ["*"]
      resources  = ["*"]
      verbs      = ["*"]
    },
    {
      non_resource_urls = ["*"]
      verbs             = ["*"]
    },
  ]
}

resource "kubernetes_cluster_role_binding" "flux" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name = "flux"

    labels {
      name = "flux"
      app  = "flux"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "${kubernetes_cluster_role.flux.metadata.0.name}"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "${kubernetes_service_account.flux.metadata.0.name}"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"
  }
}

# TODO: Limit scope
#  github.com/weaveworks/flux/cluster/kubernetes/cached_disco.go:100: Failed to list *v1beta1.CustomResourceDefinition: customresourcedefinitions.apiextensions.k8s.io is forbidden: User "system:serviceaccount:flux:flux" cannot list resource "customresourcedefinitions" in API group "apiextensions.k8s.io" at the cluster scope
#resource "kubernetes_role_binding" "flux" {
#  depends_on = ["google_container_cluster.vault"]
#
#  metadata {
#    name      = "flux"
#    namespace = "${kubernetes_namespace.flux.metadata.0.name}"
#
#    labels {
#      name = "flux"
#      app  = "flux"
#    }
#  }
#
#  role_ref {
#    api_group = "rbac.authorization.k8s.io"
#    kind      = "ClusterRole"
#    name      = "${kubernetes_cluster_role.flux.metadata.0.name}"
#  }
#
#  subject {
#    kind      = "ServiceAccount"
#    name      = "${kubernetes_service_account.flux.metadata.0.name}"
#    namespace = "${kubernetes_namespace.flux.metadata.0.name}"
#  }
#}
#
#resource "kubernetes_role_binding" "flux-vault" {
#  depends_on = ["google_container_cluster.vault"]
#
#  metadata {
#    name      = "flux"
#    namespace = "${kubernetes_namespace.vault.metadata.0.name}"
#
#    labels {
#      name = "flux"
#      app  = "flux"
#    }
#  }
#
#  role_ref {
#    api_group = "rbac.authorization.k8s.io"
#    kind      = "ClusterRole"
#    name      = "${kubernetes_cluster_role.flux.metadata.0.name}"
#  }
#
#  subject {
#    kind      = "ServiceAccount"
#    name      = "${kubernetes_service_account.flux.metadata.0.name}"
#    namespace = "${kubernetes_namespace.flux.metadata.0.name}"
#  }
#}

resource "kubernetes_secret" "flux-git-deploy" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "flux-git-deploy"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels {
      name = "flux"
      app  = "flux"
    }
  }

  data {
    identity = "${var.flux_ssh_private_key}"
  }

  type = "kubernetes.io/Opaque"
}

resource "kubernetes_deployment" "flux-memcached" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "memcached"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels {
      name = "memcached"
      app  = "flux"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        name = "memcached"
        app  = "flux"
      }
    }

    template {
      metadata {
        labels {
          name = "memcached"
          app  = "flux"
        }
      }

      spec {
        container {
          image = "memcached:${var.kubernetes_memcached_version}"
          name  = "memcached"

          args = [
            "-m 512",
            "-I 5m",
            "-p 11211",
          ]

          port = [
            {
              name           = "clients"
              container_port = 11211
            },
          ]

          resources {
            limits {
              cpu    = "250m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "memcached" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "memcached"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels {
      name = "memcached"
      app  = "flux"
    }
  }

  spec {
    selector {
      app  = "${kubernetes_deployment.flux-memcached.metadata.0.labels.app}"
      name = "${kubernetes_deployment.flux-memcached.metadata.0.labels.name}"
    }

    port {
      port = 11211
      name = "memcached"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_deployment" "flux" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "flux"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels {
      name = "flux"
      app  = "flux"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        name = "flux"
        app  = "flux"
      }
    }

    template {
      metadata {
        labels {
          name = "flux"
          app  = "flux"
        }
      }

      spec {
        service_account_name = "${kubernetes_service_account.flux.metadata.0.name}"

        volume = [
          {
            name = "git-key"

            secret = {
              default_mode = 0400
              secret_name  = "${kubernetes_secret.flux-git-deploy.metadata.0.name}"
            }
          },
          {
            name = "git-keygen"

            empty_dir = {
              medium = "Memory"
            }
          },
          {
            name = "${kubernetes_service_account.flux.default_secret_name}"

            secret = {
              secret_name = "${kubernetes_service_account.flux.default_secret_name}"
            }
          },
        ]

        container {
          image = "quay.io/weaveworks/flux:${var.kubernetes_flux_version}"
          name  = "flux"

          args = ["${compact(concat(list(
            "--memcached-hostname=memcached.${kubernetes_namespace.flux.metadata.0.name}.svc.cluster.local",
            "--listen-metrics=:3031",
            "--git-ci-skip",
            "--ssh-keygen-dir=/var/fluxd/keygen",
            "--git-url=${var.flux_repo_git_url}",
            "--git-branch=${var.flux_repo_git_branch}",
            "--git-label=${var.flux_repo_git_label}",
            "--git-poll-interval=${var.flux_repo_git_poll_interval}",
            "--sync-garbage-collection=${var.flux_sync_garbage_collection}",
					  format("--k8s-namespace-whitelist=%s", kubernetes_namespace.flux.metadata.0.name),
					  format("--k8s-namespace-whitelist=%s", kubernetes_namespace.vault.metadata.0.name),
          ),
					formatlist("--git-path=%s", var.flux_repo_git_paths),
					))}"]

          volume_mount = [
            {
              name       = "git-key"
              mount_path = "/etc/fluxd/ssh"
              read_only  = true
            },
            {
              name       = "git-keygen"
              mount_path = "/var/fluxd/keygen"
            },
            {
              name       = "${kubernetes_service_account.flux.default_secret_name}"
              mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
              read_only  = true
            },
          ]

          port = [
            {
              name           = "api"
              container_port = 3030
            },
            {
              name           = "metrics"
              container_port = 3031
            },
          ]

          resources {
            limits {
              cpu    = "500m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }
}

## Build the URL for the keys on GCS
#data "google_storage_object_signed_url" "keys" {
#  bucket = "${google_storage_bucket.vault.name}"
#  path   = "root-token.enc"
#
#  credentials = "${base64decode(google_service_account_key.vault.private_key)}"
#
#  depends_on = ["null_resource.wait-for-finish"]
#}
#
## Download the encrypted recovery unseal keys and initial root token from GCS
#data "http" "keys" {
#  url = "${data.google_storage_object_signed_url.keys.signed_url}"
#}
#
## Decrypt the values
#data "google_kms_secret" "keys" {
#  crypto_key = "${google_kms_crypto_key.vault-init.id}"
#  ciphertext = "${data.http.keys.body}"
#}
#
## Output the initial root token
#output "root_token" {
#  value = "${data.google_kms_secret.keys.plaintext}"
#}
#
# Uncomment this if you want to decrypt the token yourself
output "root_token_decrypt_command" {
  value = "gsutil cat gs://${google_storage_bucket.vault.name}/root-token.enc | base64 --decode | gcloud kms decrypt --project ${google_project.vault.project_id} --location ${var.region} --keyring ${google_kms_key_ring.vault.name} --key ${google_kms_crypto_key.vault-init.name} --ciphertext-file - --plaintext-file -"
}
