variable "vcluster_config_path" {
  type = string
}

provider "kubernetes" {
  config_path = var.vcluster_config_path
}

provider "helm" {
  kubernetes = {
    config_path = var.vcluster_config_path
  }
}

resource "kubernetes_namespace" "test" {
  metadata {
    name = "test"
  }
}
