terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
    }
  }
}

provider "kubernetes" {}

variable "test_namespace" {
  type    = string
  default = "test-ns"
}

variable "test_dockerconfig" {
  type    = string
  default = "{\"auths\":{\"harbor.example.com\":{\"username\":\"robot\",\"password\":\"secret\"}}}"
}

module "harbor_namespace_inject" {
  source = "../../../modules/harbor-namespace-inject"

  namespace    = var.test_namespace
  dockerconfig = var.test_dockerconfig
}
