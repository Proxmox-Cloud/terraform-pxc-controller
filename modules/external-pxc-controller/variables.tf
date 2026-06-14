locals {
  cloud_controller_image = var.cloud_controller_image == null ? "tobiashvmz/pve-cloud-controller" : var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version == null ? "3.2.4" : var.cloud_controller_version
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

locals {
  default_exclude_tls_namespaces = [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "nginx-ingress", "ceph-csi", "pxc-controller-ext"
  ]
}

variable "log_level" {
  type = string
  default = "INFO"
}