# Multi cloud gateway

Pick one kubernetes cluster in your cloud and elect it to be the central multi cloud gateway.

But first you need to generate a central multi cloud token that will be used by all proxmox clouds you want to peer:

```tf
# generate random token for multi cloud communication
resource "random_password" "multi_cloud_token" {
  length           = 32
  special          = true
}

resource "pxc_cloud_secret" "multi_cloud_token" {
  secret_name = "multi-cloud-token"
  secret_data = jsonencode({
    token = random_password.multi_cloud_token.result
  })
}

output "multi_cloud_token" {
  value = nonsensitive(random_password.multi_cloud_token.result)
}
```

To give the token to other clusters, use the terraform `pxc_cloud_secret` and `pxc_cloud_age_secret` resources.

This module should get a `depends_on = [ module.controller ]`, as it needs the namespace of the main module.

For the discovery to pick up you need to run `terraform apply` twice.

## External Kubernetes Clusters

Deploying the gateway also enables the usage of external-* pxc cloud controller functionalities. The discovery and secret generation is automatic.