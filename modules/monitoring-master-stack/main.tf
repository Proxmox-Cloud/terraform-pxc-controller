resource "kubernetes_namespace" "mon_ns" {
  metadata {
    name = "pve-cloud-monitoring-master"
  }
}

module "mon_shared" {
  source = "../monitoring-shared"
  namespace = kubernetes_namespace.mon_ns.metadata[0].name
  monitor_proxmox_cluster = true
  graphite_exporter_port = var.graphite_exporter_port
  optional_scrape_pve_hosts = var.optional_scrape_pve_hosts
  extra_scrape_configs = var.extra_scrape_configs

  enable_temperature_rules = var.enable_temperature_rules
  cpu_temperature_warn = var.cpu_temperature_warn
  thermal_temperature_warn = var.thermal_temperature_warn
  disk_temperature_warn = var.disk_temperature_warn
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)
}

resource "helm_release" "kube_prom_stack" {
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"

  name             = "kube-prometheus-stack"
  namespace        = "pve-cloud-monitoring-master"
  create_namespace = true

  version = "72.9.1"

  values = [
    module.mon_shared.scrape_config,
    module.mon_shared.rules,
    # additional master stack based rules
    yamlencode({
      additionalPrometheusRulesMap = var.extra_alert_rules
    }),
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

output "namespace" {
  value = helm_release.kube_prom_stack.namespace
}