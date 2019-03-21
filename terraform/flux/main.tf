locals {
  labels = {
    app      = "flux"
    instance = "${var.flux_instance}"
  }

  basename  = "${format("flux-%s",var.flux_instance)}"
  namespace = "${local.basename}"
}

resource "null_resource" "dependency_getter" {
  provisioner "local-exec" {
    command = "echo ${length(var.dependencies)}"
  }
}

resource "null_resource" "dependency_setter" {
  depends_on = [
    # List resource(s) that will be constructed last within the module.
    "kubernetes_deployment.flux",

    "kubernetes_deployment.flux-memcached",
  ]
}

# Create the namespace
resource "kubernetes_namespace" "flux" {
  depends_on = ["null_resource.dependency_getter"]

  metadata {
    annotations {
      name = "${local.namespace}"
    }

    labels = "${local.labels}"
    name   = "${local.namespace}"
  }
}

# Flux deployment
resource "kubernetes_service_account" "flux" {
  metadata {
    name      = "${local.basename}-sa"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels = "${local.labels}"
  }
}

resource "kubernetes_cluster_role" "flux" {
  metadata {
    name   = "${local.basename}"
    labels = "${local.labels}"
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
  metadata {
    name   = "${local.basename}"
    labels = "${local.labels}"
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
  metadata {
    name      = "${local.basename}-ssh-key"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels = "${local.labels}"
  }

  data {
    identity = "${var.flux_ssh_private_key}"
  }

  type = "kubernetes.io/Opaque"
}

resource "kubernetes_deployment" "flux-memcached" {
  metadata {
    name      = "${local.basename}-memcached"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels = "${merge(map("name","${local.basename}-memcached"), local.labels)}"
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        name = "${local.basename}-memcached"
      }
    }

    template {
      metadata {
        labels = "${merge(map("name","${local.basename}-memcached"), local.labels)}"
      }

      spec {
        container {
          image = "memcached:${var.memcached_version}"
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
  metadata {
    name      = "${local.basename}-memcached"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels = "${merge(map("name","${local.basename}-memcached"), local.labels)}"
  }

  spec {
    selector {
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
  depends_on = ["kubernetes_cluster_role_binding.flux", "kubernetes_secret.flux-git-deploy"]

  metadata {
    name      = "${local.basename}"
    namespace = "${kubernetes_namespace.flux.metadata.0.name}"

    labels = "${merge(map("name","${local.basename}-fluxd"), local.labels)}"
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        name = "${local.basename}-fluxd"
      }
    }

    template {
      metadata {
        labels = "${merge(map("name","${local.basename}-fluxd"), local.labels)}"
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
            "--memcached-hostname=${local.basename}-memcached.${kubernetes_namespace.flux.metadata.0.name}.svc.cluster.local",
            "${var.disable_registry_scan == "true" ? "--registry-exclude-image=*" : ""}",
            "--listen-metrics=:3031",
            "--git-ci-skip",
            "--ssh-keygen-dir=/var/fluxd/keygen",
            "--k8s-secret-name=${kubernetes_secret.flux-git-deploy.metadata.0.name}",
            "--git-url=${var.flux_repo_git_url}",
            "--git-branch=${var.flux_repo_git_branch}",
            "--git-label=${var.flux_repo_git_label}",
            "--git-poll-interval=${var.flux_repo_git_poll_interval}",
            "--sync-interval=${var.flux_sync_interval}",
            "--sync-garbage-collection=${var.flux_sync_garbage_collection}",
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

output "depended_on" {
  value = "${null_resource.dependency_setter.id}"
}
