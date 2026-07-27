# we need to do these shenanigans because we cannot pass variables conditionally to this module during tdd
# the formatting has to stay exactly the same for the auto gitlab ci variables to be able to update the version
locals {
  cloud_controller_image = var.cloud_controller_image == null ? "tobiashvmz/pve-cloud-controller" : var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version == null ? "3.4.1" : var.cloud_controller_version
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

variable "adm_controller_replicas" {
  type = number
  default = 2
}

variable "exclude_mirror_namespaces" {
  type = list(string)
  description = "Namespaces to exclude from harbor registry mirroring (admission controller hook)."
  default = []
}

variable "default_exclude_mirror_namespaces" {
  type = list(string)
  description = "Namespaces that are default excluded from mirroring, this can be overwritten for e2e."
  default = [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller", 
    "nginx-ingress", "ceph-csi", "pve-cloud-backup",
    "pve-cloud-monitoring-master", "pve-cloud-monitoring-client"
  ]
}

variable "exclude_tls_namespaces" {
  type = list(string)
  description = "Namespaces that dont get cluster-tls injected."
  default = []
}

# route53 credentials, if specified this will enable external ingress dns
variable "route53_access_key_id" {
  type = string
  default = null
  description = "Route53 credentials, when specified the controller will try to use external DNS."
}

variable "route53_secret_access_key" {
  type = string
  default = null
}

variable "route53_region" {
  type = string
  default = "eu-central-1" 
}

variable "external_forwarded_ip" {
  type = string
  default = null
  description = "The ip used in external dns while creating route53 records. Should point to the forwarded ip you use. In combination with multi cloud this will also be send to the update hook."
}

# this is optional and used for e2e testing with moto aws mock
variable "route53_endpoint_url" {
  type = string
  default = null
}

variable "log_level" {
  type = string
  default = "INFO"
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

variable "harbor_e2e_mirror_host" {
  type = string
  default = null
  description = "Select a specific e2e test injected mirror secret to use instead of default discovery."
}