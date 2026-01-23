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
  pve_inventory = var.monitor_proxmox_cluster ? yamldecode(data.pxc_pve_inventory.inv[0].inventory) : {}

  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

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

output "scrape_configs" {
  # list of yaml strings with configs
  value = [
    var.monitor_proxmox_cluster ? yamlencode({
        prometheus = {
            prometheusSpec = {
                additionalScrapeConfigs = [
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
                ]
            }
        }
    }) : "{}",
    var.monitor_proxmox_cluster && var.graphite_exporter_port != null ? yamlencode({
        prometheus = {
            prometheusSpec = {
                additionalScrapeConfigs = [
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
                ]
            }
        }
    }) : "{}",
  ]
}

output "rules" {
  value = var.monitor_proxmox_cluster ? templatefile("${path.module}/shared-rules.yaml.tftpl", {
      enable_temperature_rules = var.enable_temperature_rules
      cpu_temperature_warn     = var.cpu_temperature_warn
      thermal_temperature_warn = var.thermal_temperature_warn
      disk_temperature_warn    = var.disk_temperature_warn
    }) : "{}"
}