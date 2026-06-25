# init core scenario
variable "test_pve_conf" {
  type = string
}

variable "cloud_controller_image" {
  type = string
  default = null
}

variable "cloud_controller_version" {
  type = string
  default = null
}

locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

variable "e2e_kubespray_inv" {
  type = string
}

variable "dev_machine_ipv4" {
  type = string
  default = null
}

provider "pxc" {
  inventory = var.e2e_kubespray_inv
}

resource "time_sleep" "wait_for_moto" {
  depends_on =  [ kubernetes_manifest.moto_deployment, kubernetes_manifest.moto_service ]

  create_duration = "1m"
}

resource "kubernetes_namespace" "moto_mock" {
  metadata {
    name = "moto-mock"
  }
}

# deploy a moto server for testing external ingress dns
resource "kubernetes_manifest" "moto_deployment" {
  manifest = yamldecode(<<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: pve-cloud-moto
      namespace: ${kubernetes_namespace.moto_mock.metadata[0].name}
      labels:
        app.kubernetes.io/name: pve-cloud-moto
    spec:
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: pve-cloud-moto
      template:
        metadata:
          labels:
            app.kubernetes.io/name: pve-cloud-moto
        spec:
          containers:
            - name: moto
              image:  motoserver/moto:5.1.17
              imagePullPolicy: IfNotPresent
              ports:
                - name: http
                  containerPort: 5000
                  protocol: TCP
  YAML
  )
}

resource "kubernetes_manifest" "moto_service" {
  manifest = yamldecode(<<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: pve-cloud-moto
      namespace: ${kubernetes_namespace.moto_mock.metadata[0].name}
    spec:
      type: NodePort
      ports:
        - port: 5000
          targetPort: http
          nodePort: 30500
          protocol: TCP
          name: http
      selector:
          app.kubernetes.io/name: pve-cloud-moto

  YAML
  )
}

module "controller" {
  depends_on = [ time_sleep.wait_for_moto ]
  source = "../../../"

  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version
  
  adm_controller_replicas = 1 # for easier log reading

  route53_access_key_id = "test"
  route53_secret_access_key = "test"
  external_forwarded_ip = "127.0.0.1" # test too
  route53_endpoint_url = "http://pve-cloud-moto.moto-mock.svc.cluster.local:5000"

  # exclude harbor from mirroring if e2e suite is configured with external harbor mirror
  exclude_mirror_namespaces = contains(keys(local.test_pve_conf["kubernetes"]), "harbor_copy_mirror_host") ? [] : ["harbor"]

  # widen mirroring if external mirror is defined
  default_exclude_mirror_namespaces = contains(keys(local.test_pve_conf["kubernetes"]), "harbor_copy_mirror_host") ? [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller",
    "nginx-ingress", "ceph-csi", "pve-cloud-backup",
  ] : [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller", 
    "nginx-ingress", "ceph-csi", "pve-cloud-backup",
    "pve-cloud-monitoring-master", "pve-cloud-monitoring-client"
  ]

  log_level = "DEBUG"

  node_selector = {
    "kubernetes.io/os" = "linux"
  }

  tolerations = [
    {
      "key" = "example"
      "operator" = "Equal"
      "value" = "test"
      "effect" = "NoSchedule"
     }
  ]

  harbor_e2e_mirror_host = contains(keys(local.test_pve_conf["kubernetes"]), "harbor_copy_mirror_host") ?  local.test_pve_conf["kubernetes"]["harbor_copy_mirror_host"] : null
}

resource "time_sleep" "wait_for_controller" {
  depends_on =  [ module.controller ]

  create_duration = "1m"
}

module "multi_cloud_gateway" {
  depends_on = [ module.controller ]
  source = "../../../modules/multi-cloud-gw"

  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version
  
  mc_gw_replicas = 1 # for easier log reading

  multi_cloud_token = "DEMO-MC-TOKEN"
  multi_cloud_gateway_host = "pxc-mc-gw.${local.test_pve_conf["kubernetes"]["deployments_domain"]}"
  multi_cloud_peers = [ "http://${var.dev_machine_ipv4}:8888" ]

  node_selector = {
    "kubernetes.io/os" = "linux"
  }

  tolerations = [
    {
      "key" = "example"
      "operator" = "Equal"
      "value" = "test"
      "effect" = "NoSchedule"
     }
  ]
}


# test age secret
resource "pxc_cloud_age_secret" "test" {
  secret_name = "age-test"
  b64_age_data = "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNzaC1lZDI1NTE5IDduUjFPUSBIRWRFMWV4OEFEUkpYb3dYQkdJdFhRMkg3eTBNRE5OVFlRMXZiMlRwSFFvCnd4ZytPbFFZUWdmaXlpRlh4eEdQNVJhSGtHQTlJcGkyU2hOTlZnYjlyN00KLS0tIGFnMXM3Z3F6d29JSHQ0L1R5NFVwRFJiQnJXT0hHS01wNjJVRWRrTEtHbUEKbeE1QaFmvnKPZQd3zNkGq8z5J/r6r97jFmrAVGb5YklwLdbtg3xFiZA5LiigWAoLt/mqfLo="
}

output "age_out" {
  value = jsondecode(pxc_cloud_age_secret.test.plain_data)
}

# deploy a harbor as central artifactory, for caching and mirroring
# these tests require the fields pve_test_k8s_tls_copy_* to be set in the test env file
resource "random_password" "harbor_pw" {
  length = 24
  special = false
}

resource "kubernetes_namespace_v1" "harbor" {
  depends_on = [ time_sleep.wait_for_controller ]
  metadata {
    name = "harbor"
  }
}

resource "pxc_helm_mirror" "harbor" {
  source_repository = "https://helm.goharbor.io"
  source_name = "gohabor"
  chart = "harbor"
  version = "1.18.1"
}

resource "helm_release" "harbor" {
  repository = pxc_helm_mirror.harbor.repository_out
  chart = pxc_helm_mirror.harbor.chart
  version = pxc_helm_mirror.harbor.version
  name = "harbor"
  namespace = kubernetes_namespace_v1.harbor.metadata[0].name

  values = [
    # minimal config for ram optimized usage + nodeport for ssh shell
    <<-YML
      updateStrategy:
        type: Recreate
      expose:
        ingress:
          className: nginx
          hosts:
            core: harbor.${local.test_pve_conf["kubernetes"]["deployments_domain"]}
            notary: notary.${local.test_pve_conf["kubernetes"]["deployments_domain"]}
        tls:
          secret:
            notarySecretName: cluster-tls
            secretName: cluster-tls
          certSource: secret
      persistence:
        persistentVolumeClaim:
          registry:
            size: 250Gi
      externalURL: https://harbor.${local.test_pve_conf["kubernetes"]["deployments_domain"]}
      harborAdminPassword: ${random_password.harbor_pw.result}
    YML
  ]

  timeout = 1200
}

resource "pxc_dns_cname_record" "test_cname" {
  zone = local.test_pve_conf["kubernetes"]["deployments_domain"]
  name = "cname-test-record"
  cname = "google.de."
  ttl = 600
}
