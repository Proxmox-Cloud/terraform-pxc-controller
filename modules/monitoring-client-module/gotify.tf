# if a gotify is available inside the cloud we take this for sending alert notifications
# however if there isnt we look through our multi cloud peers and select the first
# we find for sending notifications. In the future we might want to support multiple
data "pxc_gotify_master" "gotify_master" {
  mc_peers = local.mc_peers_set
  mc_token = local.mc_token
}

# create application in gotify for notifications of the master k8s stack
resource "pxc_gotify_app" "client_app" {
  count = var.logging_only ? 0 : 1
  gotify_host = data.pxc_gotify_master.gotify_master.gotify_host
  gotify_admin_pw = data.pxc_gotify_master.gotify_master.gotify_password
  app_name = "${data.pxc_cloud_self.self.stack_name}.${data.pxc_cloud_self.self.target_pve}"
  allow_insecure = var.insecure_tls
}

# converts alertmanager receiver hook format to gotify post
resource "kubernetes_deployment" "alertmanager_gotify_bridge" {
  count = var.logging_only ? 0 : 1
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
            value = "https://${data.pxc_gotify_master.gotify_master.gotify_host}/message"
          }
          env {
            name  = "GOTIFY_TOKEN"
            value =  pxc_gotify_app.client_app[0].app_token
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

# this will create gotify notifcation matchers and targets on the proxmox cluster
# datacenter level. it will either use the gotify within the cloud or the first defined
# amongst all its cloud peers
resource "pxc_pve_gotify_target" "master_target" {
  count = var.monitor_proxmox_cluster ? 1 : 0
  gotify_host = data.pxc_gotify_master.gotify_master.gotify_host
  gotify_token = pxc_gotify_app.client_app[0].app_token
  gotify_cloud_domain = data.pxc_gotify_master.gotify_master.gotify_cloud_domain
}