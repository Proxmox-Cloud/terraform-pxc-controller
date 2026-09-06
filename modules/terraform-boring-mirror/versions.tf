terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
      version = "3.1.1"
    }
    random = {
      source = "hashicorp/random"
      version = "3.9.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>3.6.1" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}
