terraform {
  required_providers {
    harbor = {
      source = "goharbor/harbor"
      version = "3.11.3"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.38.0"
    }
  }
}
