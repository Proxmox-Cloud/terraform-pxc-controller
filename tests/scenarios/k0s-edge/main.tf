
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
resource "helm_release" "nginx_ingress" {
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart = "ingress-nginx"
  version = "4.14.0"
  name = "nginx-ingress"
  namespace = "nginx-ingress"
  create_namespace = true

  values = [<<-YAML
    controller:
      kind: DaemonSet
      # allow snippets
      allowSnippetAnnotations: true
      config:
        use-proxy-protocol: "true"
        allow-snippet-annotations: "true"
        annotations-risk-level: Critical # allow snippets that contain functions that are considered unsafe
      hostPort:
        enabled: true
      service:
        enabled: false
      extraArgs:
        enable-ssl-passthrough: "" # we use this for keycloak since it does its own tls termination always

  YAML
  ]
}


module "tf_monitoring" {
  source = "../../../modules/monitoring-client-module"

  alertmanager_host = "alrtmgr-k0s.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"

  # for testing
  insecure_tls = true

  external_pxc_vlogs_host = "vlogs.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"
}
