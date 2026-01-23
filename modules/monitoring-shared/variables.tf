variable "namespace" {
  type = string
  description = "The namespace of the monitoring stack."
}

variable "monitor_proxmox_cluster" {
  type = bool
  default = false
  description = "When set to true the underlying proxmox cluster will be monitored by this stack (inserts targets and rules)."
}

variable "graphite_exporter_port" {
  type = number
  description = "Port on haproxy to send proxmox metrics to. Needs monitor_proxmox_cluster to be set to true."
  default = null
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
