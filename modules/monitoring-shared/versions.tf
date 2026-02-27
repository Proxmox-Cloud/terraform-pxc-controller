terraform {
  required_providers {
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>3.0.2" # pxc sed ci - DONT REMOVE COMMENT!
    }
    dns = {
      source = "hashicorp/dns"
      version = "3.4.3"
    }
  }
}