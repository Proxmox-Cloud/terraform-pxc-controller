resource "random_password" "gotify_admin_pw" {
  length           = 16
  special          = true
}

resource "helm_release" "gotify" {
  repository = "https://pmoscode-helm.github.io/gotify/"
  chart = "gotify"
  version = "0.7.0"
  name = "gotify"
  namespace = helm_release.kube_prom_stack.namespace

  values = [
    <<-EOT
      server:
        defaultUserPassword: '${random_password.gotify_admin_pw.result}'
      persistence:
        enabled: true
      ingress:
        className: nginx
        enabled: true
        hosts:
          - host: gotify.${var.ingress_apex}
            paths:
              - path: /
                pathType: ImplementationSpecific
        tls:
          - hosts:
              - gotify.${var.ingress_apex}
            secretName: cluster-tls
    EOT
  ]
}

# gotify startup time
resource "time_sleep" "gotify_startup" {
  depends_on = [ helm_release.gotify ]
  create_duration = "60s"
}


# create application in gotify for notifications of the master k8s stack
resource "pxc_gotify_app" "master_app" {
  depends_on = [ time_sleep.gotify_startup ]
  gotify_host = "gotify.${var.ingress_apex}"
  gotify_admin_pw = random_password.gotify_admin_pw.result
  app_name = "${data.pxc_cloud_self.self.target_pve}"
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
            value = "https://gotify.${var.ingress_apex}/message"
          }
          env {
            name  = "GOTIFY_TOKEN"
            value = pxc_gotify_app.master_app.app_token
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

# create for later reading in client module
resource "pxc_cloud_secret" "gotify_pw" {
  secret_name = "gotify_admin_pw"
  secret_data = jsonencode({
    host = "gotify.${var.ingress_apex}"
    password = random_password.gotify_admin_pw.result
  })
}

# create gotify notification target inside proxmox
# with this proxmox errors will get send to gotify
resource "pxc_pve_gotify_target" "master_target" {
  gotify_host = "gotify.${var.ingress_apex}"
  gotify_token = pxc_gotify_app.master_app.app_token
}