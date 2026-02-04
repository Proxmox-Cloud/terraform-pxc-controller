

ephemeral "pxc_kubeconfig" "kubeconfig" {}

locals {
  kubeconfig = yamldecode(ephemeral.pxc_kubeconfig.kubeconfig.config)
}

provider "kubernetes" {
  client_certificate = base64decode(local.kubeconfig.users[0].user.client-certificate-data)
  client_key = base64decode(local.kubeconfig.users[0].user.client-key-data)
  host = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster.certificate-authority-data)
}

provider "helm" {
  kubernetes = {
    client_certificate = base64decode(local.kubeconfig.users[0].user.client-certificate-data)
    client_key = base64decode(local.kubeconfig.users[0].user.client-key-data)
    host = local.kubeconfig.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster.certificate-authority-data) 
  }
}

# init harbor provider, this scenario only gets applied when the pve_test_k8s_tls_copy_* vars are set in test env
# harbor itself already got conditionally deployed by the controller scenario

data "kubernetes_secret" "harbor_creds" {
  metadata {
    name = "harbor-core"
    namespace = "harbor"
  }
}

data "kubernetes_ingress_v1" "harbor_ingress" {
  metadata {
    name = "harbor-ingress"
    namespace = "harbor"
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