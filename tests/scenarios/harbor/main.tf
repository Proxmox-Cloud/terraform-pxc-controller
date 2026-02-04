# init core scenario
variable "test_pve_conf" {
  type = string
}

locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

variable "e2e_kubespray_inv" {
  type = string
}

provider "pxc" {
  inventory = var.e2e_kubespray_inv
}

module "harbor_mirror_projects" {
  count = contains(keys(local.test_pve_conf), "pve_test_k8s_tls_copy_target_pve") && contains(keys(local.test_pve_conf), "pve_test_k8s_tls_copy_stack_name") ? 1 : 0
  source = "../../../modules/harbor-mirror-projects"
  harbor_host = local.harbor_host
}
