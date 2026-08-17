locals {
  cloud_controller_image = var.cloud_controller_image == null ? "tobiashvmz/pve-cloud-controller" : var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version == null ? "3.5.8" : var.cloud_controller_version
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
    "pve-cloud-monitoring-master", "pve-cloud-monitoring-client",
    "pxc-controller-ext"
  ]
}
