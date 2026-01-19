variable "k8s_stack_name" {
  type = string
}

variable "gotify_host" {
  type = string
  description = "Master stack gotify address. Needed to register application for this client stack."
}

variable "gotify_admin_pw" {
  type = string
  description = "Administrator password for gotify to register this stack."
}

variable "alertmanager_host" {
  type = string
  description = "Host to expose this stacks alertmanager under. This then needs to be inserted into the master monitoring stack to bundle alerts."
}

variable "alertmanager_basic_pw" {
  type = string
  description = "Basic password for accessing this alert manager via https."
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