variable "namespace" {
  type = string
}

variable "dockerconfig" {
  type = string
}

resource "kubernetes_secret" "pull_secret" {
  type = "kubernetes.io/dockerconfigjson"
  metadata {
    namespace = var.namespace
    # name also needs to be exactly this for the inject to trigger
    name = "cluster-pull-secret"
    annotations = {
      # cloud controller checks the presence of this secret annotation
      # and injects it into all service accounts of the namespace
      "pve-cloud-pull-secret" = "sa-inject" 
    }
  }

  data = {
    ".dockerconfigjson" = var.dockerconfig
  }
}
