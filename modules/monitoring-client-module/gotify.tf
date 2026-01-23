data "pxc_cloud_secret" "gotify_admin_pw" {
  secret_name = "gotify_admin_pw"
}

locals {
  gotify_admin_pw = jsondecode(data.pxc_cloud_secret.gotify_admin_pw.secret_data)
}

# create application in gotify for notifications of the master k8s stack
resource "pxc_gotify_app" "client_app" {
  gotify_host = local.gotify_admin_pw.host
  gotify_admin_pw = local.gotify_admin_pw.password
  app_name = "${data.pxc_cloud_self.self.stack_name}.${data.pxc_cloud_self.self.target_pve}"
  allow_insecure = var.insecure_tls
}

# converts alertmanager receiver hook format to gotify post
resource "kubernetes_deployment" "alertmanager_gotify_bridge" {
  metadata {
    name      = "alertmanager-gotify"
    namespace = helm_release.kube_prom_stack.namespace
    labels = {
      app = "alertmanager-gotify"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "alertmanager-gotify"
      }
    }

    template {
      metadata {
        labels = {
          app = "alertmanager-gotify"
        }
      }

      spec {
        container {
          name  = "alertmanager-gotify"
          image = "druggeri/alertmanager_gotify_bridge:latest"
          port {
            container_port = 8080
          }
          env {
            name  = "GOTIFY_ENDPOINT"
            value = "https://${local.gotify_admin_pw.host}/message"
          }
          env {
            name  = "GOTIFY_TOKEN"
            value =  pxc_gotify_app.client_app.app_token
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "alertmanager_gotify" {
  metadata {
    name      = "alertmanager-gotify"
    namespace = helm_release.kube_prom_stack.namespace
  }

  spec {
    selector = {
      app = "alertmanager-gotify"
    }

    port {
      protocol    = "TCP"
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }
}