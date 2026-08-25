resource "kubernetes_namespace" "mon_ns" {
  metadata {
    name = "pve-cloud-monitoring-master"
  }
}

output "namespace" {
  value = kubernetes_namespace.mon_ns.metadata[0].name
}

module "mon_shared" {
  source = "../monitoring-shared"
  namespace = kubernetes_namespace.mon_ns.metadata[0].name
  monitor_proxmox_cluster = true
  optional_scrape_pve_hosts = var.optional_scrape_pve_hosts
  extra_scrape_configs = var.extra_scrape_configs

  enable_temperature_rules = var.enable_temperature_rules
  cpu_temperature_warn = var.cpu_temperature_warn
  thermal_temperature_warn = var.thermal_temperature_warn
  disk_temperature_warn = var.disk_temperature_warn

  victorialogs_host = "vlogs.${var.ingress_apex}"
  victorialogs_pvc_size = var.victorialogs_pvc_size
  victorialogs_sc_name = var.victorialogs_sc_name
  victorialogs_vector_tolerations = var.victorialogs_vector_tolerations
  victorialogs_k8s_override_expressions = var.victorialogs_k8s_override_expressions
  victorialogs_systemd_override_expressions = var.victorialogs_systemd_override_expressions
  victorialogs_extra_helm_values = var.victorialogs_extra_helm_values
  vector_daemonset_memory_limit = var.vector_daemonset_memory_limit

  tolerations = var.tolerations
  node_selector = var.node_selector
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)
}

resource "pxc_helm_mirror" "kube_prom_stack" {
  source_repository = "https://prometheus-community.github.io/helm-charts"
  source_name = "prom-community"
  chart = "kube-prometheus-stack"
  version = "72.9.1"
}

resource "helm_release" "kube_prom_stack" {
  repository = pxc_helm_mirror.kube_prom_stack.repository_out
  chart      = pxc_helm_mirror.kube_prom_stack.chart

  name             = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.mon_ns.metadata[0].name
  create_namespace = false
  
  version = pxc_helm_mirror.kube_prom_stack.version

  values = [
    module.mon_shared.scrape_config,
    module.mon_shared.rules,
    # additional master stack based rules
    yamlencode({
      additionalPrometheusRulesMap = var.extra_alert_rules
    }),
    yamlencode({
      grafana = var.grafana_subchart_values
    }), # custom values for grafana config (oidc pass)
    module.mon_shared.tolerations_snippet,
    # alertmanager settings and notification piping
    yamlencode({
      alertmanager = {
        ingress = {
          enabled = var.alertmanger_e2e_ingress
          ingressClassName = "nginx"
          hosts = [
            "alertmgr.${var.ingress_apex}"
          ]
        }
        config = {
          route = {
            group_by = ["alertname", "job", "namespace", "stack", "host"]
            group_wait = "5s" # send almost instantly
            group_interval = "10s"
            repeat_interval = "999h" # alerts are never resend, keep gotify clean
            receiver = "null"
            routes = [
              {
                receiver = "null"
                matchers = [
                  "alertname = \"Watchdog\"" # dont send default watchdog alert => pipe to null receiver
                ]
              },
              {
                receiver = "gotify"
                matchers = [
                  "severity = \"critical\"" # only send critical errors to gotify, warnings are handled by looking at the karma ui
                ]
              }
            ]
          }
          receivers = [
            {
              name = "gotify"
              webhook_configs = [
                {
                  url = "http://alertmanager-gotify.pve-cloud-monitoring-master.svc.cluster.local/gotify_webhook" # internal service
                  send_resolved = false
                }
              ]
            },
            {
              # null receiver like /dev/null
              name = "null"
            }
          ]
        }
      }
    })
  ]
}


