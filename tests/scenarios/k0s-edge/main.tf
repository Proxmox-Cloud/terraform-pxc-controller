
variable "e2e_k0s_ext_hosts_inv" {
  type = string
}

variable "cloud_controller_image" {
  type = string
  default = null
}

variable "cloud_controller_version" {
  type = string
  default = null
}
provider "pxc" {
  inventory = var.e2e_k0s_ext_hosts_inv
}
variable "test_pve_conf" {
  type = string
}

locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

resource "kubernetes_namespace" "test" {
  metadata {
    name = "test"
  }
}

module "ext_pxc_controller" {
  source = "../../../modules/external-pxc-controller"
  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version

  log_level = "DEBUG"
}

module "external_acme" {
  source = "../../../modules/external-acme-tls-csr"
  cert_config = [
    {
      zone = local.test_pve_conf["kubernetes"]["deployments_domain"]
      apex_zone_san = true
      names = [ "k0s-acme-test", "k0s-acme-test2" ]
    },
    {
      zone = "test.zone"
      names = [ "k0s-acme-test" ]
    }
  ]
}
