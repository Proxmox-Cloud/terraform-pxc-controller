terraform {
  required_providers {
    harbor = {
      source = "goharbor/harbor"
      version = "3.11.3"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "~>0.2.7" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}
