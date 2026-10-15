variable "test_namespace" {
  type    = string
}

variable "test_dockerconfig" {
  type    = string
}

module "harbor_namespace_inject" {
  source = "../../../modules/harbor-namespace-inject"

  namespace    = var.test_namespace
  dockerconfig = var.test_dockerconfig
}
