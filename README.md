# Proxmox Cloud Controller Module

Installs the proxmox cloud controller deployment on K8S.

In the [samples](https://github.com/Proxmox-Cloud/pve_cloud/blob/master/samples/kubespray-cluster/terraform/cloud-deployments.tf) you can see the [kubnernetes proxmox cloud controller](https://registry.terraform.io/modules/Proxmox-Cloud/controller/pxc/latest) being deployed with minimal features enabled.

The deployment comes with a varity of features that are toggled on by passing optional terraform variables to the terraform module:

* internal ingress dns (all kubernetes ingress resources automatically create record within the pve cloud BIND dns server)
=> this allows to reuse domains accross clusters
* optional external ingress dns (only for route53 at the moment). If you pass appropriate route53 credentials the controller also can extend the ingress capabilities to external aws route53
* optional tls certificate injection on namespace creation (the created tls k8s secret is always named `cluster-tls` for ease of use in ingress resources)
* automatic image mirroring via harbor. If you pass credentials to a harbor artificatory instance for pulling images and set it up according to the `harbor-mirror-projects` tf module, pods will be automatically patched to fetch ingresses from harbor proxy repositories instead.

## Harbor modules

The collection doesn't provide a harbor deployment, instead it integrates with one you deploy yourself, as you see fit.

Here is an example of how to quickly deploy it with terraform:

```tf
resource "random_password" "harbor_pw" {
  length = 24
}

resource "helm_release" "harbor" {
  repository = "https://helm.goharbor.io"
  chart = "harbor"
  version = "1.18.1"
  name = "harbor"
  namespace = "harbor"
  create_namespace = true

  values = [
    <<-YML
      # set this for smooth deployments / upgrades
      updateStrategy:
        type: Recreate
      expose:
        ingress:
          className: nginx
          hosts:
            core: harbor.$YOURDOMAIN
            notary: notary.$YOURDOMAIN
        tls:
          secret:
            notarySecretName: cluster-tls
            secretName: cluster-tls
          certSource: secret
      persistence:
        persistentVolumeClaim:
          registry:
            size: 250Gi
      externalURL: https://harbor.$YOURDOMAIN
      harborAdminPassword: ${random_password.harbor_pw.result}
    YML
  ]
}
```

After you have deployed this use the harbor terraform provider and our `harbor-mirror-projects`, `harbor-cluster-robot` and `harbor-namespace-inject` modules to integrate it into the cloud:

```tf
data "kubernetes_secret" "harbor_creds" {
  metadata {
    name = "harbor-core"
    namespace = "harbor"
  }
}

data "kubernetes_ingress_v1" "harbor_ingress" {
  metadata {
    name = "harbor-ingress"
    namespace = "harbor"
  }
}

locals {
  harbor_host = data.kubernetes_ingress_v1.harbor_ingress.spec[0].rule[0].host
}

provider "harbor" {
  url = "https://${local.harbor_host}"
  username = "admin"
  password = data.kubernetes_secret.harbor_creds.data["HARBOR_ADMIN_PASSWORD"]
}

# for example create a generic access robot for your entire harbor
module "harbor_access" {
  source = "Proxmox-Cloud/controller/pxc//modules/harbor-cluster-robot"
  version = "XXX"
  scope_name = "k8s"
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
  harbor_host = local.harbor_host
}

output "harbor_pull_creds" {
  value = {
    full_name = nonsensitive(module.harbor_access.robot_creds.full_name)
    secret = nonsensitive(module.harbor_access.robot_creds.secret)
    dockerconfig = nonsensitive(module.harbor_access.robot_creds.dockerconfig)
  }
}

# deploy mirroring proxy caches and full mirror repos => this enables the use of `harbor_mirror_host` variable on the controller deployment
# and will dynamically cache and create a full mirror of any images used in your cluster
module "harbor_mirror_projects" {
  source = "Proxmox-Cloud/controller/pxc//modules/harbor-mirror-projects"
  version = "XXX"
  harbor_host = local.harbor_host
}
```