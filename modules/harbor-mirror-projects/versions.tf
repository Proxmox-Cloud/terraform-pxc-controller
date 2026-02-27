terraform {
  required_providers {
    harbor = {
      source = "goharbor/harbor"
      version = "3.11.3"
    }
    pxc = {
      source = "Proxmox-Cloud/pxc"
      version = "3.0.3-rc0" # pxc sed ci - DONT REMOVE COMMENT!
    }
  }
}
