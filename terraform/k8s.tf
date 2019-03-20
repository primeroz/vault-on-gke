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
resource "kubernetes_namespace" "argocd" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    annotations {
      name = "${var.kubernetes_namespace_argocd}"
    }

    labels {
      scope = "${var.kubernetes_namespace_argocd}"
    }

    name = "${var.kubernetes_namespace_argocd}"
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

# kubectl apply - Terraform doesn't yet support CRDs
data "template_file" "argocd_crd" {
  template = "${file("${path.module}/../argocd/crd.yaml")}"

  vars {
    project   = "${google_kms_key_ring.vault.project}"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"
  }
}

resource "null_resource" "argocd_crd" {
  triggers {
    host                   = "${md5(google_container_cluster.vault.endpoint)}"
    username               = "${md5(google_container_cluster.vault.master_auth.0.username)}"
    password               = "${md5(google_container_cluster.vault.master_auth.0.password)}"
    client_certificate     = "${md5(google_container_cluster.vault.master_auth.0.client_certificate)}"
    client_key             = "${md5(google_container_cluster.vault.master_auth.0.client_key)}"
    cluster_ca_certificate = "${md5(google_container_cluster.vault.master_auth.0.cluster_ca_certificate)}"
  }

  depends_on = ["google_container_cluster.vault", "kubernetes_namespace.argocd", "kubernetes_namespace.vault"]

  provisioner "local-exec" {
    command = <<EOF
gcloud container clusters get-credentials "${google_container_cluster.vault.name}" --region="${google_container_cluster.vault.region}" --project="${google_container_cluster.vault.project}"
CONTEXT="gke_${google_container_cluster.vault.project}_${google_container_cluster.vault.region}_${google_container_cluster.vault.name}"
echo '${data.template_file.argocd_crd.rendered}' | kubectl apply --context="$CONTEXT" -n ${kubernetes_namespace.argocd.metadata.0.name} -f -
EOF
  }
}

resource "kubernetes_service_account" "argocd-application-controller" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-application-controller"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "application-controller"
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }
}

resource "kubernetes_service_account" "argocd-dex-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-dex-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "dex-server"
      "app.kubernetes.io/name"      = "argocd-dex-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }
}

resource "kubernetes_service_account" "argocd-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }
}

resource "kubernetes_role" "argocd-application-controller" {
  depends_on = ["google_container_cluster.vault", "null_resource.argocd_crd"]

  metadata {
    name      = "argocd-application-controller"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "application-controller"
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  rule = [
    {
      api_groups = [""]
      resources  = ["secrets", "configmaps"]
      verbs      = ["get", "list", "watch"]
    },
    {
      api_groups = ["argoproj.io"]
      resources  = ["applications", "appprojects"]
      verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
    },
    {
      api_groups = [""]
      resources  = ["events"]
      verbs      = ["create", "list"]
    },
  ]
}

resource "kubernetes_role" "argocd-dex-server" {
  depends_on = ["google_container_cluster.vault", "null_resource.argocd_crd"]

  metadata {
    name      = "argocd-dex-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "dex-server"
      "app.kubernetes.io/name"      = "argocd-dex-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  rule = [
    {
      api_groups = [""]
      resources  = ["secrets", "configmaps"]
      verbs      = ["get", "list", "watch"]
    },
  ]
}

resource "kubernetes_role" "argocd-server" {
  depends_on = ["google_container_cluster.vault", "null_resource.argocd_crd"]

  metadata {
    name      = "argocd-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  rule = [
    {
      api_groups = [""]
      resources  = ["secrets", "configmaps"]
      verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
    },
    {
      api_groups = ["argoproj.io"]
      resources  = ["applications", "appprojects"]
      verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
    },
    {
      api_groups = [""]
      resources  = ["events"]
      verbs      = ["create", "list"]
    },
  ]
}

resource "kubernetes_cluster_role" "argocd-application-controller" {
  depends_on = ["google_container_cluster.vault", "null_resource.argocd_crd"]

  metadata {
    name = "argocd-application-controller"

    labels {
      "app.kubernetes.io/component" = "application-controller"
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
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

resource "kubernetes_cluster_role" "argocd-server" {
  depends_on = ["google_container_cluster.vault", "null_resource.argocd_crd"]

  metadata {
    name = "argocd-server"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  rule = [
    {
      api_groups = ["*"]
      resources  = ["*"]
      verbs      = ["delete", "get", "patch"]
    },
    {
      api_groups = [""]
      resources  = ["events"]
      verbs      = ["list"]
    },
    {
      api_groups = [""]
      resources  = ["pods", "pods/log"]
      verbs      = ["get"]
    },
  ]
}

resource "kubernetes_role_binding" "argocd-application-controller" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-application-controller"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "application-controller"
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "${kubernetes_role.argocd-application-controller.metadata.0.name}"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "${kubernetes_service_account.argocd-application-controller.metadata.0.name}"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"
  }
}

resource "kubernetes_role_binding" "argocd-dex-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-dex-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "dex-server"
      "app.kubernetes.io/name"      = "argocd-dex-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "${kubernetes_role.argocd-dex-server.metadata.0.name}"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "${kubernetes_service_account.argocd-dex-server.metadata.0.name}"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"
  }
}

resource "kubernetes_role_binding" "argocd-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "${kubernetes_role.argocd-server.metadata.0.name}"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "${kubernetes_service_account.argocd-server.metadata.0.name}"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"
  }
}

resource "kubernetes_cluster_role_binding" "argocd-application-controller" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name = "argocd-application-controller"

    labels {
      "app.kubernetes.io/component" = "application-controller"
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "${kubernetes_cluster_role.argocd-application-controller.metadata.0.name}"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "${kubernetes_service_account.argocd-application-controller.metadata.0.name}"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"
  }
}

resource "kubernetes_cluster_role_binding" "argocd-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name = "argocd-server"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "${kubernetes_cluster_role.argocd-server.metadata.0.name}"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "${kubernetes_service_account.argocd-server.metadata.0.name}"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"
  }
}

resource "kubernetes_config_map" "configmap" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-cm"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/name"    = "argocd-cm"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data {
    api_host = "myhost:443"
    db_host  = "dbhost:5432"

    repositories = <<EOF
- passwordSecret:
    key: password
    name: repo-flux-vault-repo-3679211643
  url: https://gitlab.com/mintel/satoshi/experimental/flux-vault-repo.git
  usernameSecret:
    key: username
    name: repo-flux-vault-repo-3679211643
EOF
  }
}

resource "kubernetes_secret" "repo-flux-vault" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "repo-flux-vault-repo-3679211643"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/name"    = "repo-flux-vault-repo-3679211643"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data {
    username = "${var.flux_vault_repo_secret_username}"
    password = "${var.flux_vault_repo_secret_password}"
  }

  type = "kubernetes.io/Opaque"
}

#
resource "kubernetes_secret" "argocd-secret" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-secret"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/name"    = "argocd-secret"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data {
    admin.password      = "${var.argocd_admin_password}"
    admin.passwordMtime = "${var.argocd_admin_password_mtime}"
    server.secretkey    = "${var.argocd_secret_key}"
    tls.crt             = "${file("../secrets/argocd_tls.crt")}"
    tls.key             = "${file("../secrets/argocd_tls.key")}"
  }

  type = "kubernetes.io/Opaque"
}

resource "kubernetes_deployment" "argocd-application-controller" {
  depends_on = ["google_container_cluster.vault", "kubernetes_secret.argocd-secret", "kubernetes_secret.repo-flux-vault", "kubernetes_config_map.configmap", "kubernetes_role_binding.argocd-application-controller", "kubernetes_cluster_role_binding.argocd-application-controller"]

  metadata {
    name      = "argocd-application-controller"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "application-controller"
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "name"                        = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        "app.kubernetes.io/name" = "argocd-application-controller"
      }
    }

    template {
      metadata {
        labels {
          "app.kubernetes.io/name" = "argocd-application-controller"
        }
      }

      spec {
        service_account_name = "${kubernetes_service_account.argocd-application-controller.metadata.0.name}"

        volume = [
          {
            name = "${kubernetes_service_account.argocd-application-controller.default_secret_name}"

            secret = {
              secret_name = "${kubernetes_service_account.argocd-application-controller.default_secret_name}"
            }
          },
        ]

        container {
          image             = "argoproj/argocd:${var.argocd_version}"
          image_pull_policy = "Always"
          name              = "argocd-application-controller"

          volume_mount = [
            {
              name       = "${kubernetes_service_account.argocd-application-controller.default_secret_name}"
              mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
              read_only  = true
            },
          ]

          command = [
            "argocd-application-controller",
            "--status-processors",
            "20",
            "--operation-processors",
            "10",
          ]

          port = [
            {
              container_port = 8082
            },
          ]

          readiness_probe {
            tcp_socket {
              port = 8082
            }

            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            limits {
              cpu    = "250m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "argocd-dex-server" {
  depends_on = ["google_container_cluster.vault", "kubernetes_secret.argocd-secret", "kubernetes_secret.repo-flux-vault", "kubernetes_config_map.configmap", "kubernetes_role_binding.argocd-dex-server"]

  metadata {
    name      = "argocd-dex-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "dex-server"
      "app.kubernetes.io/name"      = "argocd-dex-server"
      "name"                        = "argocd-dex-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        "app.kubernetes.io/name" = "argocd-dex-server"
      }
    }

    template {
      metadata {
        labels {
          "app.kubernetes.io/name" = "argocd-dex-server"
        }
      }

      spec {
        service_account_name = "${kubernetes_service_account.argocd-dex-server.metadata.0.name}"

        volume = [
          {
            name      = "static-files"
            empty_dir = {}
          },
          {
            name = "${kubernetes_service_account.argocd-dex-server.default_secret_name}"

            secret = {
              secret_name = "${kubernetes_service_account.argocd-dex-server.default_secret_name}"
            }
          },
        ]

        init_container {
          image             = "argoproj/argocd:${var.argocd_version}"
          image_pull_policy = "Always"
          name              = "copyutil"

          command = [
            "cp",
            "/usr/local/bin/argocd-util",
            "/shared",
          ]

          volume_mount = [
            {
              name       = "static-files"
              mount_path = "/shared"
            },
          ]
        }

        container {
          image             = "quay.io/dexidp/dex:${var.dex_version}"
          image_pull_policy = "Always"
          name              = "dex"

          command = [
            "/shared/argocd-util",
            "rundex",
          ]

          volume_mount = [
            {
              name       = "static-files"
              mount_path = "/shared"
            },
            {
              name       = "${kubernetes_service_account.argocd-dex-server.default_secret_name}"
              mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
              read_only  = true
            },
          ]

          port = [
            {
              container_port = 5556
            },
            {
              container_port = 5557
            },
          ]

          #readiness_probe {
          #  http_get {
          #    path = "/healthz"
          #    port = 5556
          #    scheme = "HTTPS"
          #  }


          #  initial_delay_seconds = 5
          #  period_seconds        = 10
          #}

          resources {
            limits {
              cpu    = "250m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "argocd-redis" {
  depends_on = ["google_container_cluster.vault", "kubernetes_secret.argocd-secret", "kubernetes_secret.repo-flux-vault", "kubernetes_config_map.configmap"]

  metadata {
    name      = "argocd-redis"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "redis"
      "app.kubernetes.io/name"      = "argocd-redis"
      "name"                        = "argocd-redis"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        "app.kubernetes.io/name" = "argocd-redis"
      }
    }

    template {
      metadata {
        labels {
          "app.kubernetes.io/name" = "argocd-redis"
        }
      }

      spec {
        container {
          image             = "redis:${var.redis_version}"
          image_pull_policy = "Always"
          name              = "redis"

          args = [
            "--save",
            "",
            "--appendonly",
            "no",
          ]

          port = [
            {
              container_port = 6379
            },
          ]

          readiness_probe {
            tcp_socket {
              port = 6379
            }

            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            limits {
              cpu    = "250m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "argocd-repo-server" {
  depends_on = ["google_container_cluster.vault", "kubernetes_secret.argocd-secret", "kubernetes_secret.repo-flux-vault", "kubernetes_config_map.configmap"]

  metadata {
    name      = "argocd-repo-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "repo-server"
      "app.kubernetes.io/name"      = "argocd-repo-server"
      "name"                        = "argocd-repo-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        "app.kubernetes.io/name" = "argocd-repo-server"
      }
    }

    template {
      metadata {
        labels {
          "app.kubernetes.io/name" = "argocd-repo-server"
        }
      }

      spec {
        container {
          image             = "argoproj/argocd:${var.argocd_version}"
          image_pull_policy = "Always"
          name              = "argocd-repo-server"

          command = [
            "argocd-repo-server",
            "--redis",
            "argocd-redis:6379",
          ]

          port = [
            {
              container_port = 8081
            },
            {
              container_port = 8084
            },
          ]

          readiness_probe {
            tcp_socket {
              port = 8081
            }

            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            limits {
              cpu    = "250m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "argocd-server" {
  depends_on = ["google_container_cluster.vault", "kubernetes_secret.argocd-secret", "kubernetes_secret.repo-flux-vault", "kubernetes_config_map.configmap", "kubernetes_role_binding.argocd-server", "kubernetes_cluster_role_binding.argocd-server"]

  metadata {
    name      = "argocd-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "name"                        = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels {
        "app.kubernetes.io/name" = "argocd-server"
      }
    }

    template {
      metadata {
        labels {
          "app.kubernetes.io/name" = "argocd-server"
        }
      }

      spec {
        service_account_name = "${kubernetes_service_account.argocd-server.metadata.0.name}"

        volume = [
          {
            name      = "static-files"
            empty_dir = {}
          },
          {
            name = "${kubernetes_service_account.argocd-server.default_secret_name}"

            secret = {
              secret_name = "${kubernetes_service_account.argocd-server.default_secret_name}"
            }
          },
        ]

        init_container {
          image             = "argoproj/argocd-ui:${var.argocd_version}"
          image_pull_policy = "Always"
          name              = "ui"

          command = [
            "cp",
            "-r",
            "/app",
            "/shared",
          ]

          volume_mount = [
            {
              name       = "static-files"
              mount_path = "/shared"
            },
          ]
        }

        container {
          image             = "argoproj/argocd:${var.argocd_version}"
          image_pull_policy = "Always"
          name              = "argocd-server"

          command = [
            "argocd-server",
            "--staticassets",
            "/shared/app",
          ]

          volume_mount = [
            {
              name       = "static-files"
              mount_path = "/shared"
            },
            {
              name       = "${kubernetes_service_account.argocd-server.default_secret_name}"
              mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
              read_only  = true
            },
          ]

          port = [
            {
              container_port = 8080
            },
            {
              container_port = 8083
            },
          ]

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }

            initial_delay_seconds = 3
            period_seconds        = 30
          }

          resources {
            limits {
              cpu    = "250m"
              memory = "512Mi"
            }

            requests {
              cpu    = "50m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "argocd-dex-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-dex-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "dex-server"
      "app.kubernetes.io/name"      = "argocd-dex-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    selector {
      "app.kubernetes.io/name" = "${kubernetes_deployment.argocd-dex-server.metadata.0.labels.name}"
    }

    port = [
      {
        port        = 5556
        name        = "http"
        protocol    = "TCP"
        target_port = 5556
      },
      {
        port        = 5557
        name        = "grpc"
        protocol    = "TCP"
        target_port = 5557
      },
    ]

    type = "ClusterIP"
  }
}

resource "kubernetes_service" "argocd-metrics" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-metrics"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "metrics"
      "app.kubernetes.io/name"      = "argocd-metrics"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    selector {
      "app.kubernetes.io/name" = "${kubernetes_deployment.argocd-application-controller.metadata.0.labels.name}"
    }

    port = [
      {
        port        = 8082
        name        = "metrics"
        protocol    = "TCP"
        target_port = 8082
      },
    ]

    type = "ClusterIP"
  }
}

resource "kubernetes_service" "argocd-redis" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-redis"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "redis"
      "app.kubernetes.io/name"      = "argocd-redis"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    selector {
      "app.kubernetes.io/name" = "${kubernetes_deployment.argocd-redis.metadata.0.labels.name}"
    }

    port = [
      {
        port        = 6379
        name        = "tcp-redis"
        protocol    = "TCP"
        target_port = 6379
      },
    ]

    type = "ClusterIP"
  }
}

resource "kubernetes_service" "argocd-repo-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-repo-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "repo-server"
      "app.kubernetes.io/name"      = "argocd-repo-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    selector {
      "app.kubernetes.io/name" = "${kubernetes_deployment.argocd-repo-server.metadata.0.labels.name}"
    }

    port = [
      {
        port        = 8081
        name        = "server"
        protocol    = "TCP"
        target_port = 8081
      },
      {
        port        = 8084
        name        = "metrics"
        protocol    = "TCP"
        target_port = 8084
      },
    ]

    type = "ClusterIP"
  }
}

resource "kubernetes_service" "argocd-server-metrics" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-server-metrics"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server-metrics"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    selector {
      "app.kubernetes.io/name" = "${kubernetes_deployment.argocd-server.metadata.0.labels.name}"
    }

    port = [
      {
        port        = 8083
        name        = "metrics"
        protocol    = "TCP"
        target_port = 8083
      },
    ]

    type = "ClusterIP"
  }
}

resource "kubernetes_service" "argocd-server" {
  depends_on = ["google_container_cluster.vault"]

  metadata {
    name      = "argocd-server"
    namespace = "${kubernetes_namespace.argocd.metadata.0.name}"

    labels {
      "app.kubernetes.io/component" = "server"
      "app.kubernetes.io/name"      = "argocd-server"
      "app.kubernetes.io/part-of"   = "argocd"
    }
  }

  spec {
    selector {
      "app.kubernetes.io/name" = "${kubernetes_deployment.argocd-server.metadata.0.labels.name}"
    }

    port = [
      {
        port        = 80
        name        = "http"
        protocol    = "TCP"
        target_port = 8080
      },
      {
        port        = 443
        name        = "https"
        protocol    = "TCP"
        target_port = 8080
      },
    ]

    type = "ClusterIP"
  }
}
