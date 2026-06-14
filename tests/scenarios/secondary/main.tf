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

variable "cloud_controller_image" {
  type = string
  default = null
}

variable "cloud_controller_version" {
  type = string
  default = null
}


provider "pxc" {
  inventory = var.e2e_kubespray_inv
}

module "controller" {
  source = "../../../"

  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version
  
  adm_controller_replicas = 1 # for easier log reading

  log_level = "DEBUG"

  # set harbor host if tls is available, needs valid certificate to perform testing
  harbor_mirror_host = "harbor.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"
}

resource "time_sleep" "wait_for_controller" {
  depends_on =  [ module.controller ]

  create_duration = "1m"
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
  depends_on = [ helm_release.openebs, time_sleep.wait_for_controller ]
  source = "../../../modules/monitoring-client-module"

  alertmanager_host = "alrtmgr-secondary.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"
  victorialogs_host = "vlogs-secondary.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"

  enable_temperature_rules = true

  thermal_temperature_warn = lookup(local.test_pve_conf["terraform_parameters"], "thermal_temperature_warn", 50)
  cpu_temperature_warn = lookup(local.test_pve_conf["terraform_parameters"], "cpu_temperature_warn", 60)

  # for testing
  insecure_tls = true

  victorialogs_sc_name = "openebs-hostpath"

  node_selector = {
    "kubernetes.io/os" = "linux"
  }

  tolerations = [
    {
      "key" = "example"
      "operator" = "Equal"
      "value" = "test"
      "effect" = "NoSchedule"
     }
  ]
}

data "pxc_pve_inventory" "inv" {}

output "inv" {
  value = data.pxc_pve_inventory.inv
}

data "pxc_cloud_self" "self" {}

output "self" {
  value = data.pxc_cloud_self.self
}

# use secondary to dummy test external acme tls gen
provider "pxc" {
  cloud_domain = local.test_pve_conf["cloud_inventory"]["pve_cloud_domain"]
  target_cluster = local.test_pve_conf["pve_test_cluster_name"]
  external_stack_name = "pytest-external"
  alias = "external"
}

module "external_acme" { 
  providers = {
    pxc = pxc.external
  }

  source = "../../../modules/external-acme-tls-csr"
  cert_config = [
    {
      zone = local.test_pve_conf["kubernetes"]["deployments_domain"]
      apex_zone_san = true
      names = [ "secondary-acme-test", "secondary-acme-test2" ]
    },
    {
      zone = "test.zone"
      names = [ "acme-test" ]
    }
  ]
}

output "ext_acme_out" {
  value = {
    config = module.external_acme.config
    ec_csr = module.external_acme.ec_csr
  }
}

module "ext_pxc_controller" {
  providers = {
    pxc = pxc.external
  }

  source = "../../../modules/external-pxc-controller"
  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version

  log_level = "DEBUG"
}