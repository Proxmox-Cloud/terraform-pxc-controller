terraform {
  required_providers {
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