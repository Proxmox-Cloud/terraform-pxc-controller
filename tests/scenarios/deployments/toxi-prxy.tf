# todo: use toxiproxy to make backup procs resilient
# map config via configmap for forwards

# resource "kubernetes_namespace" "toxi" {
#   metadata {
#     name = "toxi-prxy"
#   }
# }

# resource "kubernetes_deployment_v1" "proxy" {
#   metadata {
#     name = "toxiproxy"
#     namespace = kubernetes_namespace.toxi.metadata[0].name
#     labels = {
#       app = "toxiproxy"
#     }
#   }

#   spec {
#     replicas = 1

#     selector {
#       match_labels = {
#         app = "toxiproxy"
#       }
#     }

#     template {
#       metadata {
#         labels = {
#           app = "toxiproxy"
#         }
#       }

#       spec {
#         container {
#           name  = "toxiproxy"
#           image = "ghcr.io/shopify/toxiproxy:2.12.0"

#           port {
#             name           = "toxiproxy"
#             container_port = 8474
#           }

#           # Toxiproxy proxy ports are typically exposed separately.
#           # Add additional container ports here if you configure proxies
#           # such as 8666, 8667, etc.
#         }
#       }
#     }
#   }
# }

# resource "kubernetes_service_v1" "toxiproxy" {
#   metadata {
#     name = "toxiproxy"
#     namespace = kubernetes_namespace.toxi.metadata[0].name
#   }

#   spec {
#     selector = {
#       app = "toxiproxy"
#     }

#     type = "NodePort"

#     port {
#       name        = "api"
#       port        = 8474
#       target_port = 8474
#       node_port   = 30474
#       protocol    = "TCP"
#     }
#   }
# }


# # get workers to set specific a records?
# data "pxc_dns_a_record_set" "workers" {
#   host = "workers-${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
# }

# resource "pxc_pve_graphite_exporter" "exporter" {
#   count = var.monitor_proxmox_cluster ? 1 : 0
#   exporter_name = data.pxc_cloud_self.self.stack_name
#   server = data.pxc_dns_a_record_set.workers.addrs[0]
#   port = 30109 # same as nodeport
# }
