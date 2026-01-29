resource "kubernetes_deployment" "graphite_exporter" {
  count = var.monitor_proxmox_cluster ? 1 : 0
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
  count = var.monitor_proxmox_cluster ? 1 : 0
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
      protocol    = "UDP" # udp target in proxmox ui also
      port        = 9109
      target_port = 9109
      node_port   = 30109
    }

    type = "NodePort"
  }
}


resource "kubernetes_service" "graphite_exporter" {
  count = var.monitor_proxmox_cluster ? 1 : 0
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


# find worker node, any is fine for udp metrics target
data "dns_a_record_set" "workers" {
  host = "workers-${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"
}

resource "pxc_pve_graphite_exporter" "exporter" {
  count = var.monitor_proxmox_cluster ? 1 : 0
  exporter_name = data.pxc_cloud_self.self.stack_name
  server = data.dns_a_record_set.workers.addrs[0]
  port = 30109 # same as nodeport
}