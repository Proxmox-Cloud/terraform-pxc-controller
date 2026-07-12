terraform {
  required_providers {
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>3.3.8" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}
