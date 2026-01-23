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

provider "pxc" {
  inventory = var.e2e_kubespray_inv
}

module "controller" {
  source = "../../../"

  cloud_controller_image = var.cloud_controller_image
  cloud_controller_version = var.cloud_controller_version
  
  adm_controller_replicas = 1 # for easier log reading

  route53_access_key_id = "test"
  route53_secret_access_key = "test"
  external_forwarded_ip = "127.0.0.1" # test too
  route53_endpoint_url = "http://pve-cloud-moto.moto-mock.svc.cluster.local:5000"
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

# test age secret
resource "pxc_cloud_age_secret" "test" {
  secret_name = "age-test"
  b64_age_data = "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNzaC1lZDI1NTE5IDduUjFPUSBIRWRFMWV4OEFEUkpYb3dYQkdJdFhRMkg3eTBNRE5OVFlRMXZiMlRwSFFvCnd4ZytPbFFZUWdmaXlpRlh4eEdQNVJhSGtHQTlJcGkyU2hOTlZnYjlyN00KLS0tIGFnMXM3Z3F6d29JSHQ0L1R5NFVwRFJiQnJXT0hHS01wNjJVRWRrTEtHbUEKbeE1QaFmvnKPZQd3zNkGq8z5J/r6r97jFmrAVGb5YklwLdbtg3xFiZA5LiigWAoLt/mqfLo="
}

output "age_out" {
  value = jsondecode(pxc_cloud_age_secret.test.plain_data)
}