# deploy the operator as per https://silo.pgsty.com/operations/deployments/k8s-deploy-minio-tenant-helm-on-kubernetes/
resource "pxc_helm_mirror" "minio_operator" {
  source_repository = "https://operator.min.io"
  source_name = "minio"
  chart = "operator"
  version = "7.1.1"
}

resource "helm_release" "minio_operator" {
  repository = pxc_helm_mirror.minio_operator.repository_out
  chart = pxc_helm_mirror.minio_operator.chart
  version = pxc_helm_mirror.minio_operator.version

  name = "operator"
  namespace = "minio"
  create_namespace = true

  values = [
    <<-EOT
      console:
        ingress:
          enabled: true
          ingressClassName: "nginx"
          host: minio-operator.${local.test_pve_conf["kubernetes"]["deployments_domain"]}
          tls:
            - secretName: cluster-tls
              hosts:
                - minio-operator.${local.test_pve_conf["kubernetes"]["deployments_domain"]}

    EOT
  ]

  timeout = 1200
}

# deploy a tenant (pxc e2e generic tenant)
resource "kubernetes_namespace" "tenant_ns" {
  metadata {
    name = "pxc-tenant"
  }
}

resource "random_password" "tenant_pw" {
  length = 24
}

resource "kubernetes_secret" "tenant_conf" {
  metadata {
    name = "pxc-conf"
    namespace = kubernetes_namespace.tenant_ns.metadata[0].name
  }

  data = {
    "config.env" = <<-ENV
      export MINIO_ROOT_USER="admin"
      export MINIO_ROOT_PASSWORD="${random_password.tenant_pw.result}"
    ENV
  }
}
resource "pxc_helm_mirror" "minio_tenant" {
  source_repository = "https://operator.min.io"
  source_name = "minio"
  chart = "tenant"
  version = "7.1.1"
}


# for a production environment you should use bucketDNS and generate wildcard
# certificates for the bucket aswell as a wrapping apex entry
resource "helm_release" "pxc_e2e_tenant" {
  repository = pxc_helm_mirror.minio_tenant.repository_out
  chart = pxc_helm_mirror.minio_tenant.chart
  version = pxc_helm_mirror.minio_tenant.version

  name = "pxc-e2e-tenant"
  namespace = kubernetes_namespace.tenant_ns.metadata[0].name

  values = [
    <<-EOT
      tenant:
        image:
          repository: pgsty/silo
          tag: RELEASE.2026-09-03T13-18-01Z
          pullPolicy: IfNotPresent
        env:
          - name: MINIO_UPDATE
            value: "off"
        buckets:
          - name: tf-mirror
        pools:
          - servers: 1
            name: pool-0
            volumesPerServer: 1
            size: 10Gi
            # use fast rbd csi sc just for fun
            storageClassName: csi-rbd-sc-${local.test_pve_conf["ceph_csi_storage_pool"]}-nbd
        certificate:
          requestAutoCert: false # disable auto tls, we access it only internally via http
        configSecret:
          name: ${kubernetes_secret.tenant_conf.metadata[0].name}
          existingSecret: true
      # the client needs to have direct access to the s3 minio backend as boring registry generates
      # presigned urls for artifacts and just passes them to the end user executing tf cli
      ingress:
        api:
          enabled: true
          ingressClassName: nginx
          host: "e2e-pxc-tenant.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"
          annotations:
            'nginx.ingress.kubernetes.io/proxy-body-size': '0'
          tls:
            - secretName: cluster-tls
              hosts:
                - "e2e-pxc-tenant.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"

    EOT
  ]

  timeout = 1200
}

module "tf_mirror" {
  source = "../../../modules/terraform-boring-mirror"

  namespace = kubernetes_namespace.tenant_ns.metadata[0].name
  mirror_s3_region = "minio"
  mirror_bucket_name = "tf-mirror"
  mirror_s3_endpoint = "https://e2e-pxc-tenant.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"

  boring_registry_host = "boring-registry.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"

  access_key_id = "admin"
  secret_access_key = random_password.tenant_pw.result
}
