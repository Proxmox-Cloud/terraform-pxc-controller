data "pxc_cloud_secret" "vlogs_storage_node_pw" {
  secret_name = "${local.cluster_vars.pve_cloud_domain}-vlogs-storage-node"
}

resource "kubernetes_secret" "basic_auth_secret_vlogs" {
  type = "Opaque"
  metadata {
    name = "basic-auth-vlogs"
    namespace = kubernetes_namespace.mon_ns.metadata[0].name
  }
  data = {
    "auth" : "vlogs:${bcrypt(jsondecode(data.pxc_cloud_secret.vlogs_storage_node_pw.secret_data).password)}"
  }
}

resource "pxc_cloud_secret" "vlogs_discovery" {
  secret_name = "${data.pxc_cloud_self.self.stack_name}.${data.pxc_cloud_self.self.target_pve}-vlogs"
  secret_data = jsonencode({
    host = var.victorialogs_host
    k8s_stack_name = data.pxc_cloud_self.self.stack_name
  })
  secret_type = "vlogs-storage-node"
}


resource "helm_release" "vlogs" {
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart = "victoria-logs-single"
  version = "0.11.26"
  name = "vlogs"
  namespace = kubernetes_namespace.mon_ns.metadata[0].name
  create_namespace = true

  values = [
    # minimal config for ram optimized usage + nodeport for ssh shell
    <<-YML
      vector:
        enabled: true
        customConfig:
          transforms:
            parser:
              source: |
                .log = parse_json(.message) ?? .message
                .cluster_stack = "${data.pxc_cloud_self.self.stack_name}"
                del(.message)
      server:
        persistentVolume:
          storageClassName: "${var.victorialogs_sc_name}"
        ingress:
          annotations:
            "nginx.ingress.kubernetes.io/auth-type": "basic"
            "nginx.ingress.kubernetes.io/auth-secret": "basic-auth-vlogs"
            "nginx.ingress.kubernetes.io/auth-realm": "Authentication Required" 
          enabled: true
          ingressClassName: nginx
          hosts:
            - name: ${var.victorialogs_host}
              path:
                - /
              port: http
          tls:
            - secretName: cluster-tls
              hosts:
                - ${var.victorialogs_host}
    YML
  ]

  timeout = 1200
}


resource "helm_release" "vmalert" {
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart = "victoria-metrics-alert"
  version = "0.32.0"
  name = "vmalert"
  namespace = kubernetes_namespace.mon_ns.metadata[0].name

  values = [
    <<-YML
      server:
        datasource:
          url: "http://vlogs-victoria-logs-single-server:9428"
        notifier:
          alertmanager:
            url: "http://kube-prometheus-stack-alertmanager:9093"
    YML
    , module.mon_shared.log_rules
  ]

  timeout = 1200
}