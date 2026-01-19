data "pxc_ceph_access" "ceph_access" {}

data "pxc_pve_inventory" "inv" {}

data "pxc_cluster_vars" "vars" {}

locals {
  cluster_vars = yamldecode(data.pxc_cluster_vars.vars.vars)
  # get all pve clusters in our cloud
  pve_inventory = yamldecode(data.pxc_pve_inventory.inv.inventory)
  mon_hosts = split(" ",trimspace(regex("mon_host\\s=\\s([0-9. ]+)", data.pxc_ceph_access.ceph_access.ceph_conf)[0]))
}

resource "kubernetes_secret" "basic_auth_secret" {
  type = "Opaque"
  metadata {
    name = "basic-auth"
    namespace = helm_release.kube_prom_stack.namespace
  }
  data = {
    "auth" : "karma:${bcrypt(var.alertmanager_basic_pw)}"
  }
}

resource "helm_release" "kube_prom_stack" {
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"

  name             = "kube-prometheus-stack"
  namespace        = "pve-cloud-monitoring-client"
  create_namespace = true

  version = "72.9.1"

  values = [
    # scrape targets
    yamlencode(var.monitor_proxmox_cluster ? {
      prometheus = {
        prometheusSpec = {
          additionalScrapeConfigs = concat([
            {
              job_name = "pve-systemd"
              static_configs = flatten([
                for pve_cluster, pve_hosts in local.pve_inventory : [
                  for host, host_values in pve_hosts : {
                    targets = [ "${host_values.ansible_host}:9558" ]
                    labels = {
                      "host" = "${host}.${pve_cluster}"
                      "optional" = contains(var.optional_scrape_pve_hosts, "${host}.${pve_cluster}")
                    }
                  }
                ]
              ])
            },
            {
              job_name = "pve-node"
              static_configs = flatten([
                for pve_cluster, pve_hosts in local.pve_inventory : [
                  for host, host_values in pve_hosts : {
                    targets = [ "${host_values.ansible_host}:9100" ]
                    labels = {
                      "host" = "${host}.${pve_cluster}"
                      "optional" = contains(var.optional_scrape_pve_hosts, "${host}.${pve_cluster}")
                    }
                  }
                ]
              ])
            },
            {
              # any mon ip could also contain a manager, we simply try to scrape all
              job_name = "ceph-mgrs"
              static_configs = [
                for mon in local.mon_hosts : {
                  targets = [ "${mon}:9283" ]
                  labels = {
                    "optional" = true
                  }
                }
              ]
            },
            {
              # any mon ip could also contain a manager, we simply try to scrape all
              job_name = "cluster-proxy"
              static_configs = [
                {
                  targets = [ "${local.cluster_vars.pve_haproxy_floating_ip_internal}:8405" ]
                }
              ]
            }
          ])
        }
      }
    } : {}),
    # shared rules
    var.monitor_proxmox_cluster ? file("${path.module}/../monitoring-rules-shared/pve-cluster.yaml") : "{}", # empty object to merge by helm
    var.enable_temperature_rules && var.var.monitor_proxmox_cluster ? templatefile("${path.module}/../monitoring-rules-shared/temp-rules.yaml.tftpl", {
      cpu_temperature_warn     = var.cpu_temperature_warn
      thermal_temperature_warn = var.thermal_temperature_warn
      disk_temperature_warn    = var.disk_temperature_warn
    }) : "{}",
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
  ]
}