resource "kubernetes_namespace" "pve_cloud_controller" {
  metadata {
    name = "pve-cloud-controller"
  }
}

data "pxc_cloud_self" "self" {}

data "pxc_cloud_file_secret" "bind_key" {
  secret_name = "internal.key"
}

data "pxc_cloud_file_secret" "patroni" {
  secret_name = "patroni.pass"
}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

  k8s_stack_fqdn = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"

  cluster_cert_entries = yamldecode(data.pxc_cloud_self.self.cluster_cert_entries)

  external_domains = yamldecode(data.pxc_cloud_self.self.external_domains)

  bind_dns_update_key = regex("secret\\s*\"([^\"]+)\"", data.pxc_cloud_file_secret.bind_key.secret)[0]

  pg_conn_str = "postgresql+psycopg2://postgres:${data.pxc_cloud_file_secret.patroni.secret}@${local.cluster_vars.pve_haproxy_floating_ip_internal}:5000/pve_cloud?sslmode=disable"

  default_exclude_tls_namespaces = [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "nginx-ingress", "ceph-csi", "pve-cloud-backup"
  ]
}

# harbor mirror discovery
data "pxc_cloud_secrets" "harbor_admin" {
  secret_type = "harbor-admin-auth"
}

data "pxc_cloud_secrets" "harbor_mirror" {
  secret_type = "harbor-mirror-auth"
}

locals {
  harbor_admin_secrets = jsondecode(data.pxc_cloud_secrets.harbor_admin.secrets_data)
  harbor_mirror_secrets = jsondecode(data.pxc_cloud_secrets.harbor_mirror.secrets_data)
}

check "mirror_discovery_valid" {
  assert {
    # only in e2e scenario it is valid when we find more than one discovery secret
    condition     = var.harbor_e2e_mirror_host != null || (length(local.harbor_mirror_secrets) <= 1 && length(local.harbor_admin_secrets) <= 1)
    error_message = "More than one harbor discovery secret found!"
  }
}

# specific e2e tests if variable is defined
data "pxc_cloud_secret" "e2e_harbor_mirror" {
  count = var.harbor_e2e_mirror_host != null ? 1 : 0
  secret_name = "${var.harbor_e2e_mirror_host}-mirror"
}

data "pxc_cloud_secret" "e2e_harbor_admin" {
  count = var.harbor_e2e_mirror_host != null ? 1 : 0
  secret_name = "${var.harbor_e2e_mirror_host}-admin"
}

locals {
  # prefer e2e else return first / null based on discovery secrets
  harbor_mirror_auth = var.harbor_e2e_mirror_host != null ? jsondecode(data.pxc_cloud_secret.e2e_harbor_mirror[0].secret_data) : (
    length(local.harbor_mirror_secrets) > 0 ? values(local.harbor_mirror_secrets)[0] : null
  )

  harbor_admin_auth = var.harbor_e2e_mirror_host != null ? jsondecode(data.pxc_cloud_secret.e2e_harbor_admin[0].secret_data) : (
    length(local.harbor_admin_secrets) > 0 ? values(local.harbor_admin_secrets)[0] : null
  )

  harbor_mirror_enabled = var.harbor_e2e_mirror_host != null || (local.harbor_mirror_auth != null && local.harbor_admin_auth != null)
  harbor_mirror_host = local.harbor_mirror_enabled ? local.harbor_admin_auth["harbor_host"] : null
}

# todo: this should be ported to helm so we dont have to create dummy secrets to get around terraforms limitations
# count = doesnt work here because it is sourced from unknown
resource "kubernetes_secret" "mirror_pull_secret" {
  metadata {
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    name = local.harbor_mirror_enabled ? "mirror-pull-secret" : "mps-undefined"
  }
  data = {
    ".dockerconfigjson" =  local.harbor_mirror_enabled ? local.harbor_mirror_auth.dockerconfig : "{}"
  } 

  type = "kubernetes.io/dockerconfigjson"
}


resource "kubernetes_deployment_v1" "ns_watcher" {
  metadata {
    name      = "pve-cloud-ns-watcher"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pve-cloud-ns-watcher"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pve-cloud-ns-watcher"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "pve-cloud-ns-watcher"
          "app.kubernetes.io/version" = local.cloud_controller_version
        }
      }

      spec {
        node_selector       = var.node_selector
        priority_class_name = "system-cluster-critical"

        dynamic "toleration" {
          for_each = var.tolerations != null ? var.tolerations : []
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        container {
          name              = "watcher"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["ns-watcher"]

          env {
            name  = "STACK_FQDN"
            value = local.k8s_stack_fqdn
          }
          env {
            name  = "PG_CONN_STR"
            value = local.pg_conn_str
          }
          env {
            name  = "EXCLUDE_TLS_NAMESPACES"
            value = join(",", concat(local.default_exclude_tls_namespaces, var.exclude_tls_namespaces))
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_PULL_SECRET_NAME"
              value = "mirror-pull-secret"
            }
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled != null ? [1] : []
            content {
              name  = "HARBOR_MIRROR_HOST"
              value = local.harbor_mirror_host
            }
          }

        }
      }
    }
  }
}

resource "kubernetes_deployment_v1" "pod_watcher" {
  metadata {
    name      = "pve-cloud-pod-watcher"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pve-cloud-pod-watcher"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    # pod watcher should only be deployed if a harbor for mirroring is configured
    replicas = local.harbor_mirror_enabled ? 1 : 0

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pve-cloud-pod-watcher"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "pve-cloud-pod-watcher"
          "app.kubernetes.io/version" = local.cloud_controller_version
        }
      }

      spec {
        node_selector = var.node_selector

        dynamic "toleration" {
          for_each = var.tolerations != null ? var.tolerations : []
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        container {
          name              = "watcher"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["pod-watcher"]

          env {
            name  = "EXCLUDE_MIRROR_NAMESPACES"
            value = join(",", concat(var.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))
          }

          # harbor mirror vars
          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_ADMIN_USER"
              value = local.harbor_admin_auth.full_name
            }
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_ADMIN_PASSWORD"
              value = local.harbor_admin_auth.secret
            }
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_HOST"
              value = local.harbor_mirror_host
            }
          }

        }
      }
    }
  }
}


resource "kubernetes_config_map" "cluster_cert_entries" {
  metadata {
    name      = "cluster-conf"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
  }

  data = {
    "cluster_cert_entries.json" = jsonencode(local.cluster_cert_entries)
    "external_domains.json" = jsonencode(local.external_domains)
  }
}

# check if mc is configured
data "pxc_cloud_secret" "mc_discovery" {
  secret_name = "mc_discovery"
}

locals {
  mc_parsed = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data) : null
  mc_publish_enabled = local.mc_parsed != null && length(local.mc_parsed.peers) > 0 && var.external_forwarded_ip != null
  route53_ingress_dns = var.route53_access_key_id != null && var.route53_secret_access_key != null && var.external_forwarded_ip != null
}

resource "kubernetes_deployment_v1" "adm_deployment" {
  metadata {
    name      = "pve-cloud-adm"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pve-cloud-adm"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    replicas = var.adm_controller_replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pve-cloud-adm"
      }
    }

    template {
      metadata {
        annotations = {
          "certs-checksum"       = sha256(jsonencode(local.cluster_cert_entries))
          "ext-domains-checksum" = sha256(jsonencode(local.external_domains))
        }
        labels = {
          "app.kubernetes.io/name"    = "pve-cloud-adm"
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
          name = "pve-cloud-adm-tls"
          secret {
            secret_name = "pve-cloud-adm-tls"
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

        volume {
          name = "cluster-conf"
          config_map {
            name = "cluster-conf"
          }
        }

        container {
          name              = "adm"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["gunicorn"]
          args = [
            "-w", "4",
            "--threads", "8",
            "-b", "0.0.0.0:443",
            "--certfile=/etc/tls/tls.crt",
            "--keyfile=/etc/tls/tls.key",
            "pve_cloud_ctrl.adm:app"
          ]

          volume_mount {
            name       = "pve-cloud-adm-tls"
            mount_path = "/etc/tls"
            read_only  = true
          }

          volume_mount {
            name       = "cluster-conf"
            mount_path = "/etc/controller-conf"
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
          env {
            name  = "PG_CONN_STR"
            value = local.pg_conn_str
          }
          env {
            name  = "EXCLUDE_MIRROR_NAMESPACES"
            value = join(",", concat(var.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))
          }
          env {
            name  = "BIND_MASTER_IP"
            value = local.cluster_vars.bind_master_ip
          }
          env {
            name  = "BIND_DNS_UPDATE_KEY"
            value = local.bind_dns_update_key
          }
          env {
            name  = "INTERNAL_PROXY_FIP"
            value = local.cluster_vars.pve_haproxy_floating_ip_internal
          }

          # harbor mirror vars
          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_HOST"
              value = local.harbor_mirror_host
            }
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_PULL_SECRET_NAME"
              value = "mirror-pull-secret"
            }
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_USER"
              value = local.harbor_mirror_auth.full_name
            }
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_PASSWORD"
              value = local.harbor_mirror_auth.secret
            }
          }

          # route53
          dynamic "env" {
            for_each = local.route53_ingress_dns ? [1] : []
            content {
              name  = "ROUTE53_REGION"
              value = var.route53_region
            }
          }
          dynamic "env" {
            for_each = local.route53_ingress_dns != null ? [1] : []
            content {
              name  = "ROUTE53_ACCESS_KEY_ID"
              value = var.route53_access_key_id
            }
          }
          dynamic "env" {
            for_each = local.route53_ingress_dns != null ? [1] : []
            content {
              name  = "ROUTE53_SECRET_ACCESS_KEY"
              value = var.route53_secret_access_key
            }
          }

          # external forwarded ip
          dynamic "env" {
            for_each = var.external_forwarded_ip != null ? [1] : []
            content {
              name  = "EXTERNAL_FORWARDED_IP"
              value = var.external_forwarded_ip
            }
          }

          # custom route53 endpoint (for e2e tests)
          dynamic "env" {
            for_each = var.route53_endpoint_url != null ? [1] : []
            content {
              name  = "ROUTE53_ENDPOINT_URL"
              value = var.route53_endpoint_url
            }
          }

          # mc config
          dynamic "env" {
            for_each = local.mc_publish_enabled ? [1] : []
            content {
              name  = "MC_TOKEN"
              value = local.mc_parsed.token
            }
          }
          dynamic "env" {
            for_each = local.mc_publish_enabled ? [1] : []
            content {
              name  = "MC_PEER_ENDPOINTS"
              value = join(",", local.mc_parsed.peers)
            }
          }
        }
      }
    }
  }
}


resource "kubernetes_service_v1" "adm_service" {
  metadata {
    name      = "pve-cloud-adm"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
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
      "app.kubernetes.io/name" = "pve-cloud-adm"
    }
  }
}

resource "kubernetes_mutating_webhook_configuration" "adm_hook" {
  metadata {
    name = "pve-cloud-adm"
  }

  webhook {
    name = "pod.pve-cloud-adm.pve.cloud"

    client_config {
      service {
        name      = "pve-cloud-adm"
        namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
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
  
  webhook {
    name = "ingress-dns.pve-cloud-adm.pve.cloud"

    client_config {
      service {
        name      = "pve-cloud-adm"
        namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
        path      = "/ingress-dns"
        port      = 443
      }
      ca_bundle = tls_self_signed_cert.ca.cert_pem
    }

    rule {
      api_groups   = ["networking.k8s.io"]
      api_versions = ["v1"]
      operations   = ["CREATE", "UPDATE", "DELETE"] # dynamic dns record 
      resources    = ["ingresses"]
    }

    # no selector - ingress dns for everything
    admission_review_versions = ["v1"]
    side_effects              = "None"
    failure_policy            = "Fail"
  }

  webhook {
    name = "namespace.pve-cloud-adm.pve.cloud"

    client_config {
      service {
        name      = "pve-cloud-adm"
        namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
        path      = "/delete-namespace"
        port      = 443
      }
      ca_bundle = tls_self_signed_cert.ca.cert_pem
    }

    rule {
      api_groups   = [""]
      api_versions = ["v1"]
      resources    = ["namespaces"]
      operations   = ["DELETE"]
    }

    # no selector - ingress dns for everything
    admission_review_versions = ["v1"]
    side_effects              = "None"
    failure_policy            = "Fail"
  }

}



resource "kubernetes_cron_job_v1" "cron" {
  metadata {
    name      = "pve-cloud-cron"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pve-cloud-cron"
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
              "app.kubernetes.io/name"    = "pve-cloud-cron"
              "app.kubernetes.io/version" = local.cloud_controller_version
            }
          }

          spec {
            restart_policy = "Never"
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
              name = "cluster-conf"
              config_map {
                name = "cluster-conf"
              }
            }

            container {
              name              = "cron"
              image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
              image_pull_policy = "IfNotPresent"
              command           = ["cron"]

              volume_mount {
                name = "cluster-conf"
                mount_path = "/etc/controller-conf"
                read_only = true
              }

              env {
                name  = "STACK_FQDN"
                value = local.k8s_stack_fqdn
              }
              env {
                name  = "PG_CONN_STR"
                value = local.pg_conn_str
              }

              # harbor mirror vars
              dynamic "env" {
                for_each = local.harbor_mirror_enabled ? [1] : []
                content {
                  name  = "HARBOR_MIRROR_HOST"
                  value = local.harbor_mirror_host
                }
              }

              dynamic "env" {
                for_each = local.harbor_mirror_enabled ? [1] : []
                content {
                  name  = "HARBOR_MIRROR_PULL_SECRET_NAME"
                  value = "mirror-pull-secret"
                }
              }

              env {
                name  = "BIND_MASTER_IP"
                value = local.cluster_vars.bind_master_ip
              }

              env {
                name  = "BIND_DNS_UPDATE_KEY"
                value = local.bind_dns_update_key
              }

              env {
                name  = "INTERNAL_PROXY_FIP"
                value = local.cluster_vars.pve_haproxy_floating_ip_internal
              }

              dynamic "env" {
                for_each = local.route53_ingress_dns ? [1] : []
                content {
                  name  = "ROUTE53_REGION"
                  value = var.route53_region
                }
              }

              dynamic "env" {
                for_each = local.route53_ingress_dns ? [1] : []
                content {
                  name  = "ROUTE53_ACCESS_KEY_ID"
                  value = var.route53_access_key_id
                }
              }

              dynamic "env" {
                for_each = local.route53_ingress_dns ? [1] : []
                content {
                  name  = "ROUTE53_SECRET_ACCESS_KEY"
                  value = var.route53_secret_access_key
                }
              }

              dynamic "env" {
                for_each = var.external_forwarded_ip != null ? [1] : []
                content {
                  name  = "EXTERNAL_FORWARDED_IP"
                  value = var.external_forwarded_ip
                }
              }

              dynamic "env" {
                for_each = var.route53_endpoint_url != null ? [1] : []
                content {
                  name  = "ROUTE53_ENDPOINT_URL"
                  value = var.route53_endpoint_url
                }
              }

              env {
                name  = "EXCLUDE_MIRROR_NAMESPACES"
                value = join(",", concat(var.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))
              }

              env {
                name  = "EXCLUDE_TLS_NAMESPACES"
                value = join(",", concat(local.default_exclude_tls_namespaces, var.exclude_tls_namespaces))
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


resource "kubernetes_job_v1" "init_job" {
  # tf sucking balls yet again
  lifecycle {
    ignore_changes = [
      spec[0].selector,
    ]
  }

  metadata {
    name      = "pve-cloud-init"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    labels = {
      "app.kubernetes.io/name"    = "pve-cloud-init"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    backoff_limit = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"    = "pve-cloud-init"
          "app.kubernetes.io/version" = local.cloud_controller_version
        }
      }

      spec {
        node_selector  = var.node_selector
        restart_policy = "Never"

        dynamic "toleration" {
          for_each = var.tolerations != null ? var.tolerations : []
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        volume {
          name = "cluster-conf"
          config_map {
            name = "cluster-conf"
          }
        }

        container {
          name              = "init"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["cron"]

          volume_mount {
            name       = "cluster-conf"
            mount_path = "/etc/controller-conf"
            read_only  = true
          }

          env {
            name  = "STACK_FQDN"
            value = local.k8s_stack_fqdn
          }
          env {
            name  = "PG_CONN_STR"
            value = local.pg_conn_str
          }

          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_HOST"
              value = local.harbor_mirror_host
            }
          }
          dynamic "env" {
            for_each = local.harbor_mirror_enabled ? [1] : []
            content {
              name  = "HARBOR_MIRROR_PULL_SECRET_NAME"
              value = "mirror-pull-secret"
            }
          }

          env {
            name  = "BIND_MASTER_IP"
            value = local.cluster_vars.bind_master_ip
          }
          env {
            name  = "BIND_DNS_UPDATE_KEY"
            value = local.bind_dns_update_key
          }
          env {
            name  = "INTERNAL_PROXY_FIP"
            value = local.cluster_vars.pve_haproxy_floating_ip_internal
          }

          dynamic "env" {
            for_each = local.route53_ingress_dns ? [1] : []
            content {
              name  = "ROUTE53_REGION"
              value = var.route53_region
            }
          }

          dynamic "env" {
            for_each = local.route53_ingress_dns ? [1] : []
            content {
              name  = "ROUTE53_ACCESS_KEY_ID"
              value = var.route53_access_key_id
            }
          }

          dynamic "env" {
            for_each = local.route53_ingress_dns ? [1] : []
            content {
              name  = "ROUTE53_SECRET_ACCESS_KEY"
              value = var.route53_secret_access_key
            }
          }
          
          dynamic "env" {
            for_each = var.external_forwarded_ip != null ? [1] : []
            content {
              name  = "EXTERNAL_FORWARDED_IP"
              value = var.external_forwarded_ip
            }
          }

          dynamic "env" {
            for_each = var.route53_endpoint_url != null ? [1] : []
            content {
              name  = "ROUTE53_ENDPOINT_URL"
              value = var.route53_endpoint_url
            }
          }

          env {
            name  = "EXCLUDE_MIRROR_NAMESPACES"
            value = join(",", concat(var.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))
          }
          env {
            name  = "EXCLUDE_TLS_NAMESPACES"
            value = join(",", concat(local.default_exclude_tls_namespaces, var.exclude_tls_namespaces))
          }
        }
      }
    }
  }
}
