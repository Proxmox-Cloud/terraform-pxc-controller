variable "alertmanager_host" {
  type = string
  description = "Host to expose this stacks alertmanager under. This is needed for the master monitoring stack to bundle and discover alerts."
}

variable "victorialogs_host" {
  type = string
  description = "Host to expxose victorialogs under, this will be picked up by the master stack and the multilevel chart for aggregated log search."
}

variable "victorialogs_sc_name" {
  type = string
  description = "Specific storage class to use for victoria logs db. If undefined defaults to the default class."
  default = ""
}

variable "victorialogs_pvc_size" {
  type = string
  default = "10Gi"
}

variable "victorialogs_vector_tolerations" {
  type = list(any)
  description = "Extra tolerations for vector log collector daemonset."
  default =  []
}

variable "grafana_subchart_values" {
  type = any
  default = {}
}

variable "monitor_proxmox_cluster" {
  type = bool
  default = false
  description = "When set to true the underlying proxmox cluster will be monitored by this stack (inserts targets, rules and collect host logs). This tries to collect ceph metrics aswell, so the proxmox cluster needs ceph setupped and running!"
}

variable "optional_scrape_pve_hosts" {
  type = list(string)
  default = []
}

variable "enable_temperature_rules" {
  type = bool
  default = false
}

variable "cpu_temperature_warn" {
  type = number
  default = 60
}

variable "thermal_temperature_warn" {
  type = number
  default = 50
}

variable "disk_temperature_warn" {
  type = number
  default = 50
}

variable "insecure_tls" {
  type = bool
  default = false
  description = "For testing purposes."
}

variable "victorialogs_k8s_override_rules" {
  type = map(string)
  default = {}
  description = <<-EOT
    Here you can write specialized log alerting rules for specific namespaces. Any namespaces defined here will no longer be subject to the default log alerting rules.
    They keys specified will be the k8s namespace, while the value should be a yaml string containing a list of alerting rules for victoria-metrics-alert chart,
    they will be injected into server.config.alerts.groups[].rules[].
  EOT
}

variable "victorialogs_systemd_override_rules" {
  type = map(string)
  default = {}
  description = "Same as var.victorialogs_k8s_override_rules but for the systemd services."
}

variable "victorialogs_extra_helm_values" {
  type = string
  default = "{}"
  description = "Extra value that will be added to the victorialogs single db helm deployment. Needs to be a yaml string."
}