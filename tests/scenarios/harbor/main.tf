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
  source = "../../../modules/harbor-mirror-projects"
  harbor_host = local.harbor_host
}
