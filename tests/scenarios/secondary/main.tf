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
  harbor_e2e_mirror_host = contains(keys(local.test_pve_conf["kubernetes"]), "harbor_copy_mirror_host") ?  local.test_pve_conf["kubernetes"]["harbor_copy_mirror_host"] : null

  # widen mirroring if external mirror is defined
  default_exclude_mirror_namespaces = contains(keys(local.test_pve_conf["kubernetes"]), "harbor_copy_mirror_host") ? [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller",
    "nginx-ingress", "ceph-csi", "pve-cloud-backup",
  ] : [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller", 
    "nginx-ingress", "ceph-csi", "pve-cloud-backup",
    "pve-cloud-monitoring-master", "pve-cloud-monitoring-client"
  ]
}

resource "time_sleep" "wait_for_controller" {
  depends_on =  [ module.controller ]

  create_duration = "1m"
}

resource "pxc_helm_mirror" "openebs" {
  source_repository = "https://openebs.github.io/openebs"
  source_name = "openebs"
  chart = "openebs"
  version = "4.4.0"
}

resource "helm_release" "openebs" {
  repository = pxc_helm_mirror.openebs.repository_out
  chart = pxc_helm_mirror.openebs.chart
  version = pxc_helm_mirror.openebs.version
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


data "pxc_cloud_secret" "mc_discovery" {
  secret_name = "mc_discovery"
}

locals {
  mc_peers_set = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? toset(jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data).peers) : toset([])
  mc_token = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data).token : ""
}

data "pxc_gotify_master" "gotify_master" {
  mc_peers = local.mc_peers_set
  mc_token = local.mc_token
}


# debug
resource "pxc_helm_mirror" "kube_prom_stack" {
  source_repository = "https://prometheus-community.github.io/helm-charts"
  source_name = "prom-community"
  chart = "kube-prometheus-stack"
  version = "72.9.1"
}


# resource "helm_release" "kube_prom_stack" {
#   repository = pxc_helm_mirror.kube_prom_stack.repository_out
#   chart      = pxc_helm_mirror.kube_prom_stack.chart

#   name             = "tigger"
#   namespace        = "tigger"
#   create_namespace = true

#   version = pxc_helm_mirror.kube_prom_stack.version
# }