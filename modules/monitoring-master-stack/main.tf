data "pxc_pve_inventory" "inv" {}

locals {
  # get all pve clusters in our cloud
  pve_inventory = yamldecode(data.pxc_pve_inventory.inv.inventory)

  target_pves = toset([for pve_cluster, pve_hosts in local.pve_inventory : "${pve_cluster}.${data.pxc_pve_inventory.inv.cloud_domain}"])
}

data "pxc_pve_api_get" "get_vms" {
  for_each = local.target_pves
  api_path = "/cluster/resources"
  target_pve = each.key
  get_args = {
    "--type" = "vm"
  }
}

data "pxc_ceph_access" "ceph_access" {}

data "pxc_cluster_vars" "vars" {}

locals {
  cluster_vars = yamldecode(data.pxc_cluster_vars.vars.vars)

  mon_hosts = split(" ",trimspace(regex("mon_host\\s=\\s([0-9. ]+)", data.pxc_ceph_access.ceph_access.ceph_conf)[0]))

  # merge all pvesh api query results together
  pve_vm_api_response = flatten([for target_pve, get in data.pxc_pve_api_get.get_vms: jsondecode(get.json_resp)])

  # prefilter terraform if stream is stupid
  vms_with_tags = [
    for vm in local.pve_vm_api_response : vm
    if contains(keys(vm), "tags")
  ]

  systemd_mon_vms = [for vm in local.vms_with_tags : {
    name = vm.name
    stack_domain = one([for tag in split(";", vm.tags) : tag if contains(var.systemd_mon_stack_fqdns, tag)])
  } if anytrue([for stack_fqdn in var.systemd_mon_stack_fqdns : strcontains(vm.tags, stack_fqdn)])]

  stack_domains = distinct([for vm in local.systemd_mon_vms : vm.stack_domain])

  systemd_mon_vms_grouped = tomap({
    for domain in local.stack_domains :
    domain => [
      for vm in local.systemd_mon_vms : vm if vm.stack_domain == domain
    ]
  })
}

resource "helm_release" "kube_prom_stack" {
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"

  name             = "kube-prometheus-stack"
  namespace        = "pve-cloud-monitoring-master"
  create_namespace = true

  version = "72.9.1"

  values = [
    # scrape configs for all lxcs / vms that expose systemd prometheus exporter
    yamlencode({
      prometheus = {
        prometheusSpec = {
          additionalScrapeConfigs = concat([
            {
              job_name = "vms-systemd"
              static_configs = [
                for stack_domain, vms in local.systemd_mon_vms_grouped : {
                  targets = [
                    for mon_vm in vms : "${mon_vm.name}.${join(".", slice(split(".", mon_vm.stack_domain), 1, length(split(".", mon_vm.stack_domain))))}:9558"
                  ]
                  labels = {
                    "stack" = stack_domain
                  }
                }
              ]
            },
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
            # todo: build metrics for vm but solve tcp udp problem. haproxy / k8s only receive tcp, which causes the exporter
            # on the proxmox side to crash the ui if its unreachable
            # currently no rules are tied to this service and its inactive
            {
              job_name = "pve-metrics"
              dns_sd_configs = [
                {
                  names = [ "graphite-exporter-headless.pve-cloud-monitoring-master.svc.cluster.local" ]
                  type = "A"
                  port = 9108
                }
              ]
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
          ], 
          # conditional awx scrape target
          var.awx_user == null || var.awx_pass == null ? [] :
          [
            {
              job_name = "awx-metrics"
              metrics_path = "/api/v2/metrics"
              basic_auth = {
                username = var.awx_user
                password = var.awx_pass
              }
              # lower intervals cause duplicate entry errors in prometheus. this is a bug in awx https://github.com/ansible/awx/issues/15179
              # todo: lower / remove interval when fixxed
              scrape_interval = "5m"
              scheme = "http"
              static_configs = [
                {
                  targets = [
                    "awx-service.${var.awx_namespace}.svc.cluster.local:80"
                  ]
                }
              ]
            }
          ],
          var.extra_scrape_configs
          )
        }
      }
    }),
    # shared rules
    var.enable_temperature_rules ? templatefile("${path.module}/../monitoring-rules-shared/temp-rules.yaml.tftpl", {
      cpu_temperature_warn     = var.cpu_temperature_warn
      thermal_temperature_warn = var.thermal_temperature_warn
      disk_temperature_warn    = var.disk_temperature_warn
    }) : "{}",
    file("${path.module}/../monitoring-rules-shared/pve-cluster.yaml"),
    # additional master stack based rules
    yamlencode({
      additionalPrometheusRulesMap = merge(
        {
        "awx-rules" = {
          groups = [
            {
              name = "awx"
              rules = [
                {
                  alert = "awx job failed"
                  "for" = "1m"
                  expr = "awx_status_total{status=\"failed\"} > 0"
                  labels = {
                    severity = "critical"
                  }
                  annotations = {
                    summary = "One or more AWX jobs have failed."
                    description = "A total of {{ $value }} jobs have failed."
                  }
                }
              ]
            }
          ]
        }
      },
      var.extra_alert_rules)
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
