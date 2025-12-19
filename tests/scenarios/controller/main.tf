# init core scenario
variable "test_pve_conf" {
  type = string
}



locals {
  test_pve_conf = yamldecode(file(var.test_pve_conf))
}

provider "pxc" {
  target_pve = "${local.test_pve_conf["pve_test_cluster_name"]}.${local.test_pve_conf["pve_test_cloud_domain"]}"
  k8s_stack_name = "pytest-k8s"
}

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.36.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.1.0"
    }
    pxc = {
      source = "pxc/proxmox-cloud"
      version = ">= 0.0.1"
    }
  }
}

ephemeral "pxc_kubeconfig" "example" {
  
}

locals {
  kubeconfig = yamldecode(ephemeral.pxc_kubeconfig.example.config)
}

provider "kubernetes" {
  client_certificate = base64decode(local.kubeconfig.users[0].user.client-certificate-data)
  client_key = base64decode(local.kubeconfig.users[0].user.client-key-data)
  host = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster.certificate-authority-data)
}

resource "kubernetes_namespace" "testesdfdsf" {
  metadata {
    name = "rfgasfasfs"
  }
}
data "pxc_example" "example" {
}

output "test" {
  value = data.pxc_example.example
}

# module "controller" {
#   source = "../"
# }

# resource "kubernetes_namespace" "moto_mock" {
#   metadata {
#     name = "moto-mock"
#   }
# }

# # deploy a moto server for testing external ingress dns
# resource "kubernetes_manifest" "moto_deployment" {
#   manifest = yamldecode(<<-YAML
#     apiVersion: apps/v1
#     kind: Deployment
#     metadata:
#       name: pve-cloud-moto
#       namespace: ${kubernetes_namespace.moto_mock.metadata[0].name}
#       labels:
#         app.kubernetes.io/name: pve-cloud-moto
#     spec:
#       replicas: 1
#       selector:
#         matchLabels:
#           app.kubernetes.io/name: pve-cloud-moto
#       template:
#         metadata:
#           labels:
#             app.kubernetes.io/name: pve-cloud-moto
#         spec:
#           containers:
#             - name: moto
#               image:  motoserver/moto:5.1.17
#               imagePullPolicy: IfNotPresent
#               ports:
#                 - name: http
#                   containerPort: 5000
#                   protocol: TCP
#   YAML
#   )
# }

# resource "kubernetes_manifest" "moto_service" {
#   manifest = yamldecode(<<-YAML
#     apiVersion: v1
#     kind: Service
#     metadata:
#       name: pve-cloud-moto
#       namespace: ${kubernetes_namespace.moto_mock.metadata[0].name}
#     spec:
#       type: NodePort
#       ports:
#         - port: 5000
#           targetPort: http
#           nodePort: 30500
#           protocol: TCP
#           name: http
#       selector:
#           app.kubernetes.io/name: pve-cloud-moto

#   YAML
#   )
# }
