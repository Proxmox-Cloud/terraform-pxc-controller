resource "kubernetes_deployment" "graphite_exporter" {
  count = var.graphite_exporter_port != null && var.monitor_proxmox_cluster ? 1 : 0
  metadata {
    name      = "graphite-exporter"
    namespace = var.namespace
    labels = {
      app = "graphite-exporter"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "graphite-exporter"
      }
    }

    template {
      metadata {
        labels = {
          app = "graphite-exporter"
        }
      }

      spec {
        container {
          name  = "graphite-exporter"
          image = "prom/graphite-exporter:latest"
          port {
            container_port = 9108
          }
          port {
            container_port = 9109
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "graphite_exporter_nodeport" {
  count = var.graphite_exporter_port != null && var.monitor_proxmox_cluster ? 1 : 0
  metadata {
    name      = "graphite-exporter-nodeport"
    namespace = var.namespace
  }

  spec {
    selector = {
      app = "graphite-exporter"
    }

    port {
      name = "graphite"
      protocol    = "TCP"
      port        = 9109
      target_port = 9109
      node_port   = 30109
    }

    type = "NodePort"
  }
}


resource "kubernetes_service" "graphite_exporter" {
  count = var.graphite_exporter_port != null && var.monitor_proxmox_cluster ? 1 : 0
  metadata {
    name      = "graphite-exporter-headless"
    namespace = var.namespace
  }

  spec {
    selector = {
      app = "graphite-exporter"
    }

    cluster_ip = "None"

    type = "ClusterIP"
  }
}

resource "pxc_pve_graphite_exporter" "exporter" {
  count = var.graphite_exporter_port == null ? 0 : 1
  exporter_name = "graphite-${data.pxc_cloud_self.self.stack_name}"
  server = local.cluster_vars.pve_haproxy_floating_ip_internal
  port = var.graphite_exporter_port
}