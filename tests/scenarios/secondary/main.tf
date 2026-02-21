# init core scenario
variable "test_pve_conf" {
  type = string
}

locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

variable "e2e_secondary_kubespray_inv" {
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
  inventory = var.e2e_secondary_kubespray_inv
}

module "controller" {
  source = "../../../"

  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version
  
  adm_controller_replicas = 1 # for easier log reading

  log_level = "DEBUG"

  # set harbor host if tls is available, needs valid certificate to perform testing
  harbor_mirror_host = contains(keys(local.test_pve_conf), "pve_test_k8s_tls_copy_target_pve") && contains(keys(local.test_pve_conf), "pve_test_k8s_tls_copy_stack_name") ? "harbor.${local.test_pve_conf["pve_test_deployments_domain"]}" : null
}

resource "helm_release" "openebs" {
  repository = "https://openebs.github.io/openebs"
  chart = "openebs"
  version = "4.4.0"
  name = "openebs"
  namespace = "openebs"
  create_namespace = true
  values = [<<-YAML
    loki:
      enabled: false
    alloy:  
      enabled: false
    engines:
      local:
        zfs:
          enabled: false
        lvm:
          enabled: false
        rawfile:
          enabled: false
      replicated:
        mayastor:
          enabled: false
  YAML
  ]
}

// deploy the client module
module "tf_monitoring" {
  depends_on = [ helm_release.openebs ]
  source = "../../../modules/monitoring-client-module"

  alertmanager_host = "alrtmgr-secondary.${local.test_pve_conf["pve_test_deployments_domain"]}"
  victorialogs_host = "vlogs-secondary.${local.test_pve_conf["pve_test_deployments_domain"]}"

  enable_temperature_rules = true

  thermal_temperature_warn = lookup(local.test_pve_conf["pve_test_tf_parameters"], "thermal_temperature_warn", 50)

  # for testing
  insecure_tls = true

  victorialogs_sc_name = "openebs-hostpath"
}

data "pxc_pve_inventory" "inv" {
  
}

output "inv" {
  value = data.pxc_pve_inventory.inv
}

data "pxc_cloud_self" "self" {}

output "self" {
  value = data.pxc_cloud_self.self
}