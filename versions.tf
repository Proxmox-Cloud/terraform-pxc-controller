terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.36.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
    pxc = {
      source = "pxc/proxmox-cloud"
      version = "~>0.0.26" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}

