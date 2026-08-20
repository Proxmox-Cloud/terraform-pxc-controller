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

variable "victorialogs_pvc_size" {
  type = string
  default = "10Gi"
}

variable "victorialogs_vector_tolerations" {
  type = list(any)
  description = "Extra tolerations for vector log collector daemonset."
  default =  []
}

variable "victorialogs_k8s_override_expressions" {
  type = map(string)
  default = {}
  description = <<-EOT
    Here you can write specialized log alerting rules for specific namespaces (key of the map). Any namespaces defined here will no longer be subject to the default 
    log alerting rules. They keys specified will be the k8s namespace, while the value should be a yaml string containing a list of alerting rules for 
    victoria-metrics-alert chart, they will be injected into server.config.alerts.groups[].rules[].
  EOT
}

variable "victorialogs_systemd_override_expressions" {
  type = map(string)
  default = {}
  description = "Same as var.victorialogs_k8s_override_expressions but for the systemd services."
}

variable "victorialogs_extra_helm_values" {
  type = string
  default = "{}"
  description = "Extra value that will be added to the victorialogs single db helm deployment. Needs to be a yaml string."
}

variable "vmauth_config" {
  type = string
  default = <<-YAML
    vmauth:
      enabled: false
  YAML
  description = <<-EOT
    Values for vmauth subchart passed to victorialogs multilevel. This can be used to create jwt based access restriction / matching to logs.
    Defaults to disableing the vmauth subchart.
  EOT
}

variable "node_selector" {
  type = map(string)
  default = null
  description = "Optional node selector for controller deployments/jobs."
}

variable "tolerations" {
  type = list(map(string))
  default = null
  description = "Tolerations to add to all controller deployments/jobs."
}
