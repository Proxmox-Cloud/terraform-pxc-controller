
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
}

# this will trigger for controllers in the same cloud so they send updates to all peer clouds
# and receive the token from herewi
resource "pxc_cloud_secret" "mc_discovery" {
  secret_name = "mc_discovery"
  secret_data = jsonencode({
    token = var.multi_cloud_token
    peers = var.multi_cloud_peers
  })
}

# generate secrets for external kubernetes clusters that integrate with this specific cloud, from non pxc instances.
resource "random_password" "external_mc_token" {
  length           = 32
  special          = true
}

resource "pxc_cloud_secret" "external_mc_token" {
  secret_name = "external-mc-token"
  secret_data = jsonencode({
    token = random_password.external_mc_token.result
    mc_gw_host = var.multi_cloud_gateway_host
  })
}

# need to use kubernetes_deployment_v1 here since kubernetes_manifest is a buggy pos
# todo: refactor all kubernetes_manifest resources where possible
# use dynamic blocks for imiating logic
resource "kubernetes_deployment_v1" "mc_gw_deployment" {
  metadata {
    name      = "pve-cloud-mc-gw"
    namespace = "pve-cloud-controller"
    labels = {
      "app.kubernetes.io/name"    = "pve-cloud-mc-gw"
      "app.kubernetes.io/version" = local.cloud_controller_version
    }
  }

  spec {
    replicas = var.mc_gw_replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "pve-cloud-mc-gw"
      }
    }

    template {
      metadata {
        annotations = {
          "certs-checksum" = sha256(jsonencode(local.cluster_cert_entries))
        }
        labels = {
          "app.kubernetes.io/name"    = "pve-cloud-mc-gw"
          "app.kubernetes.io/version" = local.cloud_controller_version
        }
      }

      spec {
        priority_class_name = "system-cluster-critical"
        node_selector       = var.node_selector

        # Using dynamic block for tolerations to cleanly handle null/empty variables
        dynamic "toleration" {
          for_each = var.tolerations != null ? var.tolerations : []
          content {
            key               = lookup(toleration.value, "key", null)
            operator          = lookup(toleration.value, "operator", null)
            value             = lookup(toleration.value, "value", null)
            effect            = lookup(toleration.value, "effect", null)
          }
        }

        volume {
          name = "cluster-conf"
          config_map {
            name = "cluster-conf"
          }
        }

        container {
          name              = "mc-gw"
          image             = "${local.cloud_controller_image}:${local.cloud_controller_version}"
          image_pull_policy = "IfNotPresent"
          command           = ["gunicorn"]
          args = [
            "-w", "2",
            "-b", "0.0.0.0:80",
            "pve_cloud_ctrl.mc_gateway:app"
          ]

          volume_mount {
            name       = "cluster-conf"
            mount_path = "/etc/controller-conf"
            read_only  = true
          }

          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }

          env {
            name  = "LOG_LEVEL"
            value = var.log_level
          }
          env {
            name  = "PG_CONN_STR"
            value = local.pg_conn_str
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
          env {
            name  = "MC_TOKEN"
            value = var.multi_cloud_token
          }
          env {
            name = "EXTERNAL_MC_TOKEN"
            value = random_password.external_mc_token.result
          }
          env {
            name = "PVE_CLOUD_DOMAIN"
            value = local.cluster_vars.pve_cloud_domain
          }
          # Note: MC_PEER_ENDPOINTS intentionally omitted per original manifest comments
        }
      }
    }
  }
}

resource "kubernetes_manifest" "mc_gw_service" {
  manifest = yamldecode(<<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: pve-cloud-mc-gw
      namespace: pve-cloud-controller
    spec:
      type: ClusterIP
      ports:
        - port: 80
          targetPort: http
          protocol: TCP
          name: http
      selector:
          app.kubernetes.io/name: pve-cloud-mc-gw

  YAML
  )
}

resource "kubernetes_manifest" "mc_gw_ingress" {
  count = var.multi_cloud_gateway_host != null && var.multi_cloud_token != null ? 1 : 0
  manifest = yamldecode(<<-YAML
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: pve-cloud-mc-gw
      namespace: pve-cloud-controller
    spec:
      ingressClassName: nginx
      tls:
        - hosts:
            - ${var.multi_cloud_gateway_host}
          secretName: cluster-tls
      rules:
        - host: ${var.multi_cloud_gateway_host}
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: pve-cloud-mc-gw
                    port:
                      name: http

  YAML
  )
}
