# todo: evaluate moving this module to helm aswell. Helm templating may be much better suited 
# then terraform tempalting

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

  cluster_hosts = var.monitor_proxmox_cluster ? yamldecode(data.pxc_pve_inventory.inv[0].inventory)[local.cluster_vars.pve_cluster_name]["pve_hosts"] : {}

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
                    job_name = "pve-node-smartctl"
                    static_configs = flatten([
                        for host, host_values in local.cluster_hosts : {
                            targets = [ "${host_values.ansible_host}:9633" ]
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
                            names = [ "graphite-exporter-headless.${var.namespace}.svc.cluster.local" ]
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

output "tolerations_snippet" {
  value = <<-YAML
    %{ if var.node_selector != null || var.tolerations != null }
    prometheusOperator:
    %{ if var.node_selector != null }
      nodeSelector:
        ${indent(4, yamlencode(var.node_selector))}
    %{ endif }
    %{ if var.tolerations != null }
      tolerations:
        ${indent(4, yamlencode(var.tolerations))}
    %{ endif }
      admissionWebhooks:
        patch:
    %{ if var.node_selector != null }
          nodeSelector:
            ${indent(8, yamlencode(var.node_selector))}
    %{ endif }
    %{ if var.tolerations != null }
          tolerations:
            ${indent(8, yamlencode(var.tolerations))}
    %{ endif }
    %{ endif }
    %{ if var.node_selector != null || var.tolerations != null }
    prometheus:
      prometheusSpec:
    %{ if var.node_selector != null }
        nodeSelector:
          ${indent(6, yamlencode(var.node_selector))}
    %{ endif }
    %{ if var.tolerations != null }
        tolerations:
          ${indent(6, yamlencode(var.tolerations))}
    %{ endif }
    %{ endif }
    %{ if var.node_selector != null || var.tolerations != null }
    alertmanager:
      alertmanagerSpec:
    %{ if var.node_selector != null }
        nodeSelector:
          ${indent(6, yamlencode(var.node_selector))}
    %{ endif }
    %{ if var.tolerations != null }
        tolerations:
          ${indent(6, yamlencode(var.tolerations))}
    %{ endif }
    %{ endif }
    %{ if var.node_selector != null || var.tolerations != null }
    grafana:
    %{ if var.node_selector != null }
      nodeSelector:
        ${indent(4, yamlencode(var.node_selector))}
    %{ endif }
    %{ if var.tolerations != null }
      tolerations:
        ${indent(4, yamlencode(var.tolerations))}
    %{ endif }
    %{ endif }
    %{ if var.node_selector != null || var.tolerations != null }
    kube-state-metrics:
    %{ if var.node_selector != null }
      nodeSelector:
        ${indent(4, yamlencode(var.node_selector))}
    %{ endif }
    %{ if var.tolerations != null }
      tolerations:
        ${indent(4, yamlencode(var.tolerations))}
    %{ endif }
    %{ endif }
  YAML
}

data "kubernetes_nodes" "all" {}

locals {
  vect_tolerations = distinct(flatten([
    for node in data.kubernetes_nodes.all.nodes : [
      for taint in node.spec[0].taints : {
        key      = taint.key
        operator = taint.value != null && taint.value != "" ? "Equal" : "Exists"
        value    = taint.value
        effect   = taint.effect
      }
    ]
  ]))
  vector_control_plane_tolerations = [
    {
      key = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect = "NoSchedule"
    }
  ]
}

output "vl_single_config" {
  value = [
    yamlencode({
      vector = {
        tolerations = flatten([local.vector_control_plane_tolerations, var.victorialogs_vector_tolerations, local.vect_tolerations])
      }
    }),
    # minimal config for ram optimized usage + nodeport for ssh shell
    # also add pve_stack as stream field for general access filtering
    <<-YML
      vector:
        enabled: true
        resources:
          limits:
            memory: "${var.vector_daemonset_memory_limit}"
        customConfig:
          sinks:
            vlogs:
              # this reduction + the madvise setting for transparent_hugepage keeps vector
              # memory usage within limits, kubernetes can produce tons of logs, leading to unstable usage
              buffer:
                type: memory
                max_events: 100
                when_full: drop_newest
              request:
                headers:
                  VL-Stream-Fields: stream,kubernetes.pod_name,kubernetes.container_name,kubernetes.pod_namespace,pve_stack
          transforms:
            parser:
              source: |
                .log = parse_json(.message) ?? .message
                .pve_stack = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
                del(.message)
      server:
      %{ if var.node_selector != null }
        nodeSelector:
          ${indent(4, yamlencode(var.node_selector))}
      %{ endif }
      %{ if var.tolerations != null }
        tolerations:
          ${indent(4, yamlencode(var.tolerations))}
      %{ endif }
        retentionMaxDiskUsagePercent: "85" # auto delete logs larger than
        persistentVolume:
          storageClassName: "${var.victorialogs_sc_name}"
          size: "${var.victorialogs_pvc_size}"
        ingress:
          annotations:
            "nginx.ingress.kubernetes.io/auth-type": "basic"
            "nginx.ingress.kubernetes.io/auth-secret": "basic-auth-vlogs"
            "nginx.ingress.kubernetes.io/auth-realm": "Authentication Required"
            "nginx.ingress.kubernetes.io/proxy-body-size": "1G"
          enabled: true
          ingressClassName: nginx
          hosts:
            - name: ${var.victorialogs_host}
              path:
                - /
              port: http
          tls:
            - secretName: cluster-tls
              hosts:
                - ${var.victorialogs_host}
    YML
    , var.victorialogs_extra_helm_values
  ]
}


locals {
  # base generic filter for catching errors, this will be overwritten by more speicific rules
  # excludes logs that were successfully parsed via a log parser and contain the log level info
  error_base_filter = "!level: i(info) AND (i(panic) OR i(exception) OR i(fatal) OR i(critical) OR i(error) OR i(segfault))"

  # for some generic namespaces we define overwrites here, this only works though for deployments that are part of proxmox clouds core deployments
  k8s_ns_specific_base_expressions = {
    "nginx-ingress" = "kubernetes.pod_namespace: \"nginx-ingress\" and stream: \"stderr\""
    # bug / bad code in k8s 1.32 for controller manager logging fallback as error, exclude to keep alerts clean
    # also at startup WXXXX warnings for attempted connections that dont affect functionality
    "kube-system" = "${local.error_base_filter} AND !\"falling back\" AND !~\"W\\\\d+\\\\s.*addrConn.createTransport\" AND kubernetes.pod_namespace: \"kube-system\""
  }

  # here we build the filter for the default rules
  k8s_base_exclude_ns = concat(keys(local.k8s_ns_specific_base_expressions), keys(var.victorialogs_k8s_override_expressions))
  k8s_ns_filter = "kubernetes.pod_namespace:* and !kubernetes.pod_namespace: IN(${join(", ", [for ns in local.k8s_base_exclude_ns : "\"${ns}\""])})"

  # do the same for journald services
  journald_service_specific_base_expressions = {
    # named errors use syslogs priorities, anything below 5 is warning / error / critical
    "named.service" = "_SYSTEMD_UNIT: named.service and PRIORITY: <=4"
    # etcd fires warning messages on health checks, error comes in at priority 6 (Informational)
    # todo: should be optimized in prometheus alert 
    "etcd.service" = "_SYSTEMD_UNIT: etcd.service and PRIORITY: <=5"
    # kubelet service / containerd also logs a bunch of errors with priority 6
    "kubelet.service" = "_SYSTEMD_UNIT: kubelet.service and PRIORITY: <=5"
    "containerd.service" = "_SYSTEMD_UNIT: containerd.service and PRIORITY: <=5"
  }

  journald_base_exclude_services = concat(keys(local.journald_service_specific_base_expressions), keys(var.victorialogs_systemd_override_expressions))
  journald_service_filter = "_SYSTEMD_UNIT:* and !_SYSTEMD_UNIT: IN(${join(", ", [for service in local.journald_base_exclude_services : "\"${service}\""])})"
}

output "log_rules" {
  value = templatefile("${path.module}/vlogs-alert-rules.yaml.tftpl", {
    error_base_filter = local.error_base_filter
    k8s_ns_filter     = local.k8s_ns_filter
    k8s_ns_specific = merge(local.k8s_ns_specific_base_expressions, var.victorialogs_k8s_override_expressions)
    journald_service_filter = local.journald_service_filter
    journald_service_specific = merge(local.journald_service_specific_base_expressions, var.victorialogs_systemd_override_expressions)
  })
}
