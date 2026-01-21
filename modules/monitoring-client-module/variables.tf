variable "alertmanager_host" {
  type = string
  description = "Host to expose this stacks alertmanager under. This is needed for the master monitoring stack to bundle and discover alerts."
}

variable "monitor_proxmox_cluster" {
  type = bool
  default = false
  description = "When set to true the underlying proxmox cluster will be monitored by this stack (inserts targets and rules)."
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