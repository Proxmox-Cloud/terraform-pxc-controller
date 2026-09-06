resource "random_password" "boring_registry_pw" {
  length           = 24
  special          = false
}

resource "pxc_helm_mirror" "boring_registry" {
  source_repository = "oci://ghcr.io/boring-registry/charts"
  source_name = "boring"
  chart = "boring-registry"
  version = "0.23.0"
}

resource "helm_release" "boring_registry" {
  repository = pxc_helm_mirror.boring_registry.repository_out
  chart = pxc_helm_mirror.boring_registry.chart
  version = pxc_helm_mirror.boring_registry.version

  name = "boring-registry"
  namespace = var.namespace

  values = [
    <<-EOT
      server:
        debug: true
        extraArgs:
          - server
          - '--network-mirror-pull-through=true'
          # it seems this is not needed / auto fallback to pathstyle
          # - '--storage-s3-pathstyle=true'
        auth:
          value: "${random_password.boring_registry_pw.result}"
        ingress:
          enabled: true
          className: "nginx"
          hosts:
            - host: ${var.boring_registry_host}
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - secretName: cluster-tls
              hosts:
                - ${var.boring_registry_host}
        storage:
          s3:
            bucket: ${var.mirror_bucket_name}
            endpoint: ${var.mirror_s3_endpoint}
            region: ${var.mirror_s3_region}
        extraEnvs:
          - name: AWS_ACCESS_KEY_ID
            value: ${var.access_key_id}
          - name: AWS_SECRET_ACCESS_KEY
            value: "${var.secret_access_key}"
    EOT
  ]

  timeout = 1200
}

data "pxc_cloud_self" "self" {}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)
}

resource "pxc_cloud_secret" "tf_mirror_discovery" {
  secret_name = "${local.cluster_vars.pve_cloud_domain}-tf-mirror-discv"
  secret_data = jsonencode({
    host = var.boring_registry_host
    password = random_password.boring_registry_pw.result
  })
  secret_type = "tf-mirror-discovery"
}
