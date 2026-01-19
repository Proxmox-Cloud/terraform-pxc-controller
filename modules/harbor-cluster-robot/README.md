# Harbor Cluster Robot

This assumes the kubernetes provider you passed is authenticated for a k8s cluster that has harbor hosted in the harbor namespace.

With this module you can create a generic robot access to harbor used for automation.

For example you can create generic read access to your harbor like this:

```tf
module "harbor_access" {
  source = "Proxmox-Cloud/controller/pxc//modules/harbor-cluster-robot"
  version = "" # insert version here
  scope_name = "generic-read"
  harbor_permissions = [
    {
      namespace = "*"
      access = [
        {
          action = "pull"
        }
      ]
    }
  ]
}
```

In the modules output you will then find credentials to further pass along.