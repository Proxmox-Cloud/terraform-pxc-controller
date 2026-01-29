terraform {
  backend "pg" {} # sourced entirely via .envrc

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "3.1.1"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "0.2.2-rc0" # pxc sed ci - DONT REMOVE COMMENT!
    }
    dns = {
      source = "hashicorp/dns"
      version = "3.4.3"
    }
  }
}