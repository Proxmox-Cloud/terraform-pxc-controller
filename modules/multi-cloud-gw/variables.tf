# we need to do these shenanigans because we cannot pass variables conditionally to this module during tdd
# the formatting has to stay exactly the same for the auto gitlab ci variables to be able to update the version
locals {
  cloud_controller_image = var.cloud_controller_image == null ? "tobiashvmz/pve-cloud-controller" : var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version == null ? "3.3.7" : var.cloud_controller_version
}

variable "cloud_controller_image" {
  type = string
  default = null
  description = "When set to non null value will use that insead of hardcoded image in locals."
}

variable "cloud_controller_version" {
  type = string
  default = null
  description = "Image version, normally hardcoded, only set in test cases."
}

variable "mc_gw_replicas" {
  type = number
  default = 2
}

variable "multi_cloud_token" {
  type = string
  description = "When this is passed, multi cloud features will be enabled. Needs to be defined for every controller of the cloud."
}

variable "multi_cloud_gateway_host" {
  type = string
  description = "DNS Host for the multi cloud controller api. This should be passed to peers as endpoint. Only if this is defined the multi cloud gateway deployment will be created. DO THIS ONLY ONCE PER CLOUD!"
}

variable "multi_cloud_peers" {
  type = list(string)
  default = []
  description = "Endpoints of peer multi cloud controllers using the same multi cloud token. Needs to be defined for every controller of the cloud." 
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

variable "log_level" {
  type = string
  default = "INFO"
}