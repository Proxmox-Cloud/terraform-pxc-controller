# Harbor Mirror Projects

This assumes the kubernetes provider you passed is authenticated for a k8s cluster that has harbor hosted in the harbor namespace.

This module configures mirror repositories within your harbor artifactory so that they can be used by the controllers mirroring functionality.

After you initialized your harbor with this you can use the cloud controller like this to pull images from proxy repositories inside harbor instead:

```tf
data "pxc_cluster_vars" "cvars" {}

locals {
  cluster_vars = yamldecode(data.pxc_cluster_vars.cvars.vars)
}

module "cloud_controller" {
  source = "Proxmox-Cloud/controller/pxc"
  version = "" # insert version here
  k8s_stack_fqdn = "${local.inventory.stack_name}.${local.cluster_vars.pve_cloud_domain}"

  harbor_mirror_host = "harbor.$YOUR-DOMAIN"
  harbor_mirror_auth = module.harbor_cluster_robot.auth_b64
  exclude_mirror_namespaces = ["harbor", "other-system-namespace"]
}
```