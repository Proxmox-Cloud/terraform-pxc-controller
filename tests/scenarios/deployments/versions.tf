terraform {
  backend "pg" {} # sourced entirely via .envrc

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.36.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "3.1.1"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>0.1.2" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}