# if a gotify is available inside the cloud we take this for sending alert notifications
# however if there isnt we look through our multi cloud peers and select the first
# we find for sending notifications. In the future we might want to support multiple

# query the peers
data "http" "gotify_master" {
  # Convert the list to a set for for_each
  for_each = toset(local.mc_peers_set)

  url = "${each.value}/get-gotify-master"

  request_headers = {
    Authorization = "Bearer ${local.mc_token}"
    Accept        = "application/json"
  }
}

data "pxc_cloud_secret" "gotify_admin_pw" {
  secret_name = "gotify_admin_pw"
}

locals {
  mc_gotify_master_filtered = [for peer, response in data.http.gotify_master : jsondecode(response.response_body) if jsondecode(response.response_body).gotify_present ]
  target_gotify = data.pxc_cloud_secret.gotify_admin_pw.secret_data != "" ? jsondecode(data.pxc_cloud_secret.gotify_admin_pw.secret_data) : local.mc_gotify_master_filtered[0].gotify_access
}

check "multi_master" {
 assert {
   condition     = (data.pxc_cloud_secret.gotify_admin_pw.secret_data != "" && length(local.mc_gotify_master_filtered) == 0) || (data.pxc_cloud_secret.gotify_admin_pw.secret_data == "" && length(local.mc_gotify_master_filtered) == 1)
   error_message = "Master gotify within cloud / multi cloud peers not properly configured! There should only be a single master!"
 }
}

# create application in gotify for notifications of the master k8s stack
resource "pxc_gotify_app" "client_app" {
  gotify_host = local.target_gotify.host
  gotify_admin_pw = local.target_gotify.password
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
        node_selector = var.node_selector
        
        dynamic "toleration" {
          for_each = var.tolerations != null ? var.tolerations : []

          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", null)
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        container {
          name  = "alertmanager-gotify"
          image = "druggeri/alertmanager_gotify_bridge:2.3.2"
          port {
            container_port = 8080
          }
          env {
            name  = "GOTIFY_ENDPOINT"
            value = "https://${local.target_gotify.host}/message"
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