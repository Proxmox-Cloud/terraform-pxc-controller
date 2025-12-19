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

provider "pxc" {
  target_pve = "${local.test_pve_conf["pve_test_cluster_name"]}.${local.test_pve_conf["pve_test_cloud_domain"]}"
  k8s_stack_name = "pytest-k8s"
}

module "controller" {
  source = "../../../"

  k8s_stack_fqdn = "pytest-k8s.${local.test_pve_conf["pve_test_cloud_domain"]}"

  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version
  
  adm_controller_replicas = 1 # for easier log reading

  route53_access_key_id = "test"
  route53_secret_access_key = "test"
  external_forwarded_ip = "127.0.0.1" # test too
  route53_endpoint_url = "http://pve-cloud-moto.moto-mock.svc.cluster.local:5000"

  cluster_cert_entries = [
    {
      zone = local.test_pve_conf["pve_test_deployments_domain"],
      names = ["*"]
    }
  ]

  external_domains = [
    {
      zone = local.test_pve_conf["pve_test_deployments_domain"],
      names = ["external-example", "test-dns-delete"]
    }
  ]
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
