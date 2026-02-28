data "pxc_pve_inventory" "inv" {
    count = var.monitor_proxmox_cluster ? 1 : 0
}

data "pxc_cloud_vms" "vms" {
    count = var.monitor_proxmox_cluster ? 1 : 0
}

data "pxc_ceph_access" "ceph_access" {
    count = var.monitor_proxmox_cluster ? 1 : 0
}

data "pxc_cloud_self" "self" {}

// parse pxc provider data sources
locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

  cluster_hosts = var.monitor_proxmox_cluster ? yamldecode(data.pxc_pve_inventory.inv[0].inventory)[local.cluster_vars.pve_cluster_name] : {}

  ceph_mon_hosts = var.monitor_proxmox_cluster ? split(" ",trimspace(regex("mon_host\\s=\\s([0-9. ]+)", data.pxc_ceph_access.ceph_access[0].ceph_conf)[0])) : []

  # prefilter terraform if stream is stupid
  vms_with_exporter = var.monitor_proxmox_cluster ? [
    for vm in jsondecode(data.pxc_cloud_vms.vms[0].vms_json) : {
      name = vm.name
      stack_domain = one([for tag in split(";", vm.tags) : tag if endswith(tag, local.cluster_vars.pve_cloud_domain)])
    }
    if contains(keys(vm), "blake_vars") && contains(keys(vm["blake_vars"]), "install_prom_systemd_exporter") && vm["blake_vars"]["install_prom_systemd_exporter"]
  ] : []

  stack_domains = distinct([for vm in local.vms_with_exporter : vm.stack_domain])

  systemd_mon_vms_grouped = tomap({
    for domain in local.stack_domains :
    domain => [
      for vm in local.vms_with_exporter : vm if vm.stack_domain == domain
    ]
  })
}

output "scrape_config" {
  # list of yaml strings with configs
  value = var.monitor_proxmox_cluster ? yamlencode({
    prometheus = {
        prometheusSpec = {
            additionalScrapeConfigs = flatten([
            [
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
                        for host, host_values in local.cluster_hosts : {
                            targets = [ "${host_values.ansible_host}:9558" ]
                            labels = {
                                "host" = "${host}.${local.cluster_vars.pve_cluster_name}"
                                "optional" = contains(var.optional_scrape_pve_hosts, "${host}.${local.cluster_vars.pve_cluster_name}")
                            }
                        }
                    
                    ])
                },
                {
                    job_name = "pve-node"
                    static_configs = flatten([
                        for host, host_values in local.cluster_hosts : {
                            targets = [ "${host_values.ansible_host}:9100" ]
                            labels = {
                                "host" = "${host}.${local.cluster_vars.pve_cluster_name}"
                                "optional" = contains(var.optional_scrape_pve_hosts, "${host}.${local.cluster_vars.pve_cluster_name}")
                            }
                        }
                    ])
                },
                {
                    job_name = "pve-node-btrfs"
                    fallback_scrape_protocol = "PrometheusText0.0.4"
                    static_configs = flatten([
                        for host, host_values in local.cluster_hosts : {
                            targets = [ "${host_values.ansible_host}:9899" ]
                            labels = {
                                "host" = "${host}.${local.cluster_vars.pve_cluster_name}"
                                "optional" = contains(var.optional_scrape_pve_hosts, "${host}.${local.cluster_vars.pve_cluster_name}")
                            }
                        } if contains(keys(local.cluster_vars.pve_host_vars), host) && contains(keys(local.cluster_vars.pve_host_vars[host]), "install_btrfs_root_prom_exporter") && local.cluster_vars.pve_host_vars[host]["install_btrfs_root_prom_exporter"]
                    ])
                },
                {
                    # any mon ip could also contain a manager, we simply try to scrape all
                    job_name = "ceph-mgrs"
                    static_configs = [
                        for mon in local.ceph_mon_hosts : {
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
            var.extra_scrape_configs,
            var.monitor_proxmox_cluster ? [
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
            ] : []]
            )
        }
    }
  }) : "{}"
  
}

output "rules" {
  value = var.monitor_proxmox_cluster ? templatefile("${path.module}/shared-rules.yaml.tftpl", {
      enable_temperature_rules = var.enable_temperature_rules
      cpu_temperature_warn     = var.cpu_temperature_warn
      thermal_temperature_warn = var.thermal_temperature_warn
      disk_temperature_warn    = var.disk_temperature_warn
    }) : "{}"
}

output "log_rules" {
  value = <<-YAML
    server:
      config:
        alerts:
          groups:
            - name: "Log Alerts"
              type: vlogs
              rules:
                - alert: "Errors High"
                  expr: '_time:1h AND (panic OR exception OR fatal OR critical OR error OR "segfault") | stats by (kubernetes.container_name, kubernetes.pod_namespace, cluster_stack) count() total_errors | filter total_errors:>10'
                  labels:
                    severity: warning
                    namespace: '{{ index $labels "kubernetes.pod_namespace" }}'
                  annotations:
                    summary: 'Errors high in {{ index $labels "kubernetes.pod_namespace" }}.'
                    description: 'In the last hour {{ $value }} errors occured for container {{ index $labels "kubernetes.container_name" }} in k8s stack {{ index $labels "cluster_stack" }}.'
                - alert: "Errors Stats"
                  expr: '_time:1h AND (panic OR exception OR fatal OR critical OR error OR "segfault") | stats by (kubernetes.container_name, kubernetes.pod_namespace, cluster_stack) count() as total_errors'
                  labels:
                    severity: info
                    namespace: '{{ index $labels "kubernetes.pod_namespace" }}'
                  annotations:
                    summary: 'Errors in {{ index $labels "kubernetes.pod_namespace" }}.'
                    description: 'In the last hour {{ $value }} errors occured for container {{ index $labels "kubernetes.container_name" }} in k8s stack {{ index $labels "cluster_stack" }}.'
                - alert: "InfoInhibitor"
                  expr: '_time:1h AND (panic OR exception OR fatal OR critical OR error OR "segfault") | stats by (kubernetes.pod_namespace, kubernetes.container_name, cluster_stack) count() errors_per_pod | stats by (kubernetes.pod_namespace, cluster_stack) max(errors_per_pod) max_errors | filter max_errors:<=10'
                  labels:
                    severity: none
                    namespace: '{{ index $labels "kubernetes.pod_namespace" }}'
                  annotations:
                    summary: "Inhibiting Log Info Alerts"
                    description: "This is an extension to the prometheus stack default InfoInhibitor alert, extending to alerts from victoria metric logs. If any pod in a namespace has thrown more than 10 errors in the last hour, this will stop firing and the default alertmanager inhibit_rules will stop triggering, unsuppressing info log alerts for that entire namespace."

  YAML
}