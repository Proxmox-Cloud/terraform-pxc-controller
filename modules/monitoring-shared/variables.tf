variable "namespace" {
  type = string
  description = "The namespace of the monitoring stack."
}

variable "monitor_proxmox_cluster" {
  type = bool
  default = false
  description = "When set to true the underlying proxmox cluster will be monitored by this stack (inserts targets and rules). Also configures a discovery secret for pumping journald logs via vector from pve hosts and lxcs."
}

variable "optional_scrape_pve_hosts" {
  type = list(string)
  default = []
  description = "Marks certain proxmox hosts as optional, raising no alarm when they are down."
}

variable "enable_temperature_rules" {
  type = bool
  default = false
  description = "Enables monitoring for temp zones reported by the node exporter installed on pve hosts. Requires monitor_proxmox_cluster to be set to true."
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

variable "extra_scrape_configs" {
  type = list(any)
  default = []
}

variable "victorialogs_host" {
  type = string
  description = "Host to expxose victorialogs under, this will be picked up by the master stack and the multilevel chart for aggregated log search."
}

variable "victorialogs_vector_tolerations" {
  type = list(any)
  description = "Extra tolerations for vector log collector daemonset."
  default =  []
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
