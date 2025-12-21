data "kubernetes_secret" "harbor_creds" {
  metadata {
    name = "harbor-core"
    namespace = var.harbor_namespace
  }
}

data "kubernetes_ingress_v1" "harbor_ingress" {
  metadata {
    name = "harbor-ingress"
    namespace = var.harbor_namespace
  }
}

locals {
  harbor_host = data.kubernetes_ingress_v1.harbor_ingress.spec[0].rule[0].host
}

provider "harbor" {
  url = "https://${local.harbor_host}"
  username = "admin"
  password = data.kubernetes_secret.harbor_creds.data["HARBOR_ADMIN_PASSWORD"]
}