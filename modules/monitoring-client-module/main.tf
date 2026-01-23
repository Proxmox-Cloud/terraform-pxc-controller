resource "kubernetes_namespace" "mon_ns" {
  metadata {
    name = "pve-cloud-monitoring-client"
  }
}

module "mon_shared" {
  source = "../monitoring-shared"
  namespace = kubernetes_namespace.mon_ns.metadata[0].name
  monitor_proxmox_cluster = var.monitor_proxmox_cluster
  graphite_exporter_port = var.graphite_exporter_port
  optional_scrape_pve_hosts = var.optional_scrape_pve_hosts

  enable_temperature_rules = var.enable_temperature_rules
  cpu_temperature_warn = var.cpu_temperature_warn
  thermal_temperature_warn = var.thermal_temperature_warn
  disk_temperature_warn = var.disk_temperature_warn
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)
}

// save the alertmanager password so the main stack can discover it
// the entire client monitoring discovery hinges on this secret + type
resource "random_password" "alertmanager_pw" {
  length           = 16
  special          = false
}

resource "pxc_cloud_secret" "alertmanager_mon" {
  secret_name = "${data.pxc_cloud_self.self.stack_name}.${data.pxc_cloud_self.self.target_pve}"
  secret_data = jsonencode({
    host = var.alertmanager_host
    k8s_stack_name = data.pxc_cloud_self.self.stack_name
    password = random_password.alertmanager_pw.result
  })
  secret_type = "mon-alertmgr-client"
}

resource "kubernetes_secret" "basic_auth_secret" {
  type = "Opaque"
  metadata {
    name = "basic-auth"
    namespace = kubernetes_namespace.mon_ns.metadata[0].name
  }
  data = {
    "auth" : "karma:${bcrypt(random_password.alertmanager_pw.result)}"
  }
}

resource "helm_release" "kube_prom_stack" {
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"

  name             = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.mon_ns.metadata[0].name
  create_namespace = false

  version = "72.9.1"

  values = concat(module.mon_shared.scrape_configs, [
    module.mon_shared.rules,
    yamlencode({
      alertmanager = {
        # expose alertmanager via ingress for karma in master stack to fetch
        ingress = {
          annotations = {
            "nginx.ingress.kubernetes.io/auth-type" = "basic"
            "nginx.ingress.kubernetes.io/auth-secret" = "basic-auth"
            "nginx.ingress.kubernetes.io/auth-realm" = "Authentication Required" 
          }
          ingressClassName = "nginx"
          enabled = true
          hosts = [
            var.alertmanager_host
          ]
          paths = [
            "/"
          ]
          tls = [
            {
              secretName = "cluster-tls"
              hosts = [
                var.alertmanager_host
              ]
            }
          ]
        }
        config = {
          route = {
            group_by = ["alertname", "job", "namespace", "stack", "host"]
            group_wait = "5s" # send almost instantly
            group_interval = "10s"
            repeat_interval = "999h" # alerts are never resend, keep gotify clean
            receiver = "gotify"
            routes = [
              {
                receiver = "null"
                matchers = [
                  "alertname = \"Watchdog\"" # dont send default watchdog alert => pipe to null receiver
                ]
              }
            ]
          }
          receivers = [
            {
              name = "gotify"
              webhook_configs = [
                {
                  url = "http://alertmanager-gotify.pve-cloud-monitoring-client.svc.cluster.local/gotify_webhook" # internal service
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
  ])
}