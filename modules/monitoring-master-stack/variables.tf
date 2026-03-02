variable "ingress_apex" {
  type = string
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

variable "optional_scrape_pve_hosts" {
  type = list(string)
  default = []
}

variable "extra_scrape_configs" {
  type = list(any)
  default = []
}

variable "extra_alert_rules" {
  type = any
  default = {}
}

variable "grafana_subchart_values" {
  type = any
  default = {}
}

variable "external_karma_alertmanagers" {
  type = list(any)
  default = []
  description = "DEPRECATED! For backwards compatibility and intergrating systems that dont use the client-stack discovery."
}

variable "insecure_tls" {
  type = bool
  default = false
  description = "For testing purposes."
}

variable "alertmanger_e2e_ingress" {
  type = bool
  default = false
  description = "Toggle alertmanager ingress for testing purposes."
}

variable "victorialogs_sc_name" {
  type = string
  description = "Specific storage class to use for victoria logs db. If undefined defaults to the default class."
  default = ""
}

variable "victoria_logs_pvc_size" {
  type = string
  default = "10Gi"
}

variable "victorialogs_vector_tolerations" {
  type = list(any)
  description = "Extra tolerations for vector log collector daemonset."
  default =  []
}