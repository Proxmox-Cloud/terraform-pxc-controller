terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    random = {
      source = "hashicorp/random"
      version = "3.9.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>3.3.0" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}