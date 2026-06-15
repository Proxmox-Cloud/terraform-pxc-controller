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