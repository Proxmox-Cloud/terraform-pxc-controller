locals {
  default_exclude_tls_namespaces = [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "nginx-ingress", "ceph-csi", "pxc-controller-ext"
  ]
}

resource "kubernetes_namespace" "ext_pxc_controller" {
  metadata {
    name = "pxc-controller-ext"
  }
}

resource "kubernetes_manifest" "controller_access_binding" {
  manifest = yamldecode(<<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: pxc-ext-controller-binding
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      # todo: proper access rights
      name: cluster-admin
    subjects:
      - kind: ServiceAccount
        name: default
        namespace: ${kubernetes_namespace.ext_pxc_controller.metadata[0].name}
  YAML
  )
}

data "pxc_cloud_self" "self" {}

data "pxc_cloud_secret" "ext_mc_discovery" {
  secret_name = "external-mc-token"
  lifecycle {
    postcondition {
        condition     = self.secret_data != ""
        error_message = "No external discovery secret found in pxc cloud instance. Did you deploy the multi-cloud-gw?"
    }
  }
}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)
  mc_parsed = jsondecode(data.pxc_cloud_secret.ext_mc_discovery.secret_data)
}

# create ext namespace watcher deployment
resource "kubernetes_deployment_v1" "ns_watcher" {
  metadata {
    name      = "pxc-ext-ns-watcher"
    namespace = kubernetes_namespace.ext_pxc_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pxc-ext-ns-watcher"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pxc-ext-ns-watcher"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "pxc-ext-ns-watcher"
          "app.kubernetes.io/version" = local.cloud_controller_version
        }
      }

      spec {
        priority_class_name = "system-cluster-critical"

        container {
          name              = "watcher"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["ext-ns-watcher"]

          env {
            name  = "EXT_STACK_FQDN"
            value = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
          }

          env {
            name  = "MC_GW_HOST"
            value = local.mc_parsed.mc_gw_host
          }

          env {
            name = "EXTERNAL_MC_TOKEN"
            value = local.mc_parsed.token
          }

          env {
            name  = "LOG_LEVEL"
            value = var.log_level
          }

        }
      }
    }
  }
}


resource "kubernetes_cron_job_v1" "cron" {
  metadata {
    name      = "pxc-ext-cron"
    namespace = kubernetes_namespace.ext_pxc_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pxc-ext-cron"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    schedule = "0 0 * * *" # once every night

    job_template {
      metadata {}
      
      spec {
        backoff_limit = 0

        template {
          metadata {
            labels = {
              "app.kubernetes.io/name"    = "pxc-ext-cron"
              "app.kubernetes.io/version" = local.cloud_controller_version
            }
          }

          spec {
            restart_policy = "Never"

            container {
              name              = "cron"
              image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
              image_pull_policy = "IfNotPresent"
              command           = ["ext-cron"]

              env {
                name  = "EXT_STACK_FQDN"
                value = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
              }

              env {
                name  = "MC_GW_HOST"
                value = local.mc_parsed.mc_gw_host
              }

              env {
                name = "EXTERNAL_MC_TOKEN"
                value = local.mc_parsed.token
              }

              env {
                name = "EXCLUDE_TLS_NAMESPACES"
                value = join(",", local.default_exclude_tls_namespaces)
              }

              env {
                name  = "LOG_LEVEL"
                value = var.log_level
              }

            }
          }
        }
      }
    }
  }
}

# currently only used to rewrite bitnami image names
# and inject cluster-pull-secrets
resource "kubernetes_deployment_v1" "ext_adm_deployment" {
  metadata {
    name      = "pxc-ext-adm"
    namespace = kubernetes_namespace.ext_pxc_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pxc-ext-adm"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    replicas = var.adm_controller_replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pxc-ext-adm"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "pxc-ext-adm"
          "app.kubernetes.io/version" = local.cloud_controller_version
        }
      }

      spec {
        priority_class_name = "system-cluster-critical"
        node_selector       = var.node_selector

        dynamic "toleration" {
          for_each = var.tolerations != null ? var.tolerations : []
          content {
            key                = lookup(toleration.value, "key", null)
            operator           = lookup(toleration.value, "operator", null)
            value              = lookup(toleration.value, "value", null)
            effect             = lookup(toleration.value, "effect", null)
          }
        }

        volume {
          name = "pxc-ext-adm-tls"
          secret {
            secret_name = "pxc-ext-adm-tls"
            items {
              key  = "tls.crt"
              path = "tls.crt"
            }
            items {
              key  = "tls.key"
              path = "tls.key"
            }
          }
        }

        container {
          name              = "adm"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["gunicorn"]
          args = [
            "-w", "4",
            "--threads", "4",
            "-b", "0.0.0.0:443",
            "--certfile=/etc/tls/tls.crt",
            "--keyfile=/etc/tls/tls.key",
            "pve_cloud_ctrl.ext_adm:app"
          ]

          volume_mount {
            name       = "pxc-ext-adm-tls"
            mount_path = "/etc/tls"
            read_only  = true
          }

          port {
            name           = "https"
            container_port = 443
            protocol       = "TCP"
          }

          # static env vars
          env {
            name  = "LOG_LEVEL"
            value = var.log_level
          }

          # currently only used to disable pod hooks for namespaces
          env {
            name  = "EXCLUDE_MIRROR_NAMESPACES"
            value = join(",", concat(var.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))
          }
        }
      }
    }
  }
}


resource "kubernetes_service_v1" "adm_service" {
  metadata {
    name      = "pxc-ext-adm"
    namespace = kubernetes_namespace.ext_pxc_controller.metadata[0].name
  }

  spec {
    type = "ClusterIP"

    port {
      name        = "https"
      port        = 443
      target_port = "https"
      protocol    = "TCP"
    }

    selector = {
      "app.kubernetes.io/name" = "pxc-ext-adm"
    }
  }
}

resource "kubernetes_mutating_webhook_configuration" "adm_hook" {
  metadata {
    name = "pxc-ext-adm"
  }

  webhook {
    name = "pod.pxc-ext-adm.pve.cloud"

    client_config {
      service {
        name      = "pxc-ext-adm"
        namespace = kubernetes_namespace.ext_pxc_controller.metadata[0].name
        path      = "/mutate-pod"
        port      = 443
      }
      ca_bundle = tls_self_signed_cert.ca.cert_pem
    }

    rule {
      api_groups   = [""]
      api_versions = ["v1"]
      operations   = ["CREATE"]
      resources    = ["pods"]
    }

    # hook patch for pods should not trigger for all namespaces
    namespace_selector {
      match_expressions {
        key = "kubernetes.io/metadata.name"
        operator = "NotIn"
        values = concat(var.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces)
      }
    }

    admission_review_versions = ["v1"]
    side_effects              = "None"
    failure_policy            = "Fail"
  }

}
