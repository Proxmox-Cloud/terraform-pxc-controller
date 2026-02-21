
resource "random_password" "vlogs_storage_node_pw" {
  length           = 16
  special          = false
}

resource "pxc_cloud_secret" "vlogs_storage_node" {
  secret_name = "${local.cluster_vars.pve_cloud_domain}-vlogs-storage-node"
  secret_data = jsonencode({
    password = random_password.vlogs_storage_node_pw.result
  })
}

resource "kubernetes_secret" "basic_auth_secret_vlogs" {
  type = "Opaque"
  metadata {
    name = "basic-auth-vlogs"
    namespace = kubernetes_namespace.mon_ns.metadata[0].name
  }
  data = {
    "auth" : "vlogs:${bcrypt(random_password.vlogs_storage_node_pw.result)}"
  }
}

data "pxc_cloud_secrets" "vlogs_clients" {
  secret_type = "vlogs-storage-node"
}

# replace ingress with oauth / use victoria method?
resource "helm_release" "vlogs_ml" {
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart = "victoria-logs-multilevel"
  version = "0.0.9"
  name = "vlogs-ml"
  namespace = kubernetes_namespace.mon_ns.metadata[0].name
  create_namespace = true

  values = [
    # minimal config for ram optimized usage + nodeport for ssh shell
    <<-YML
      vmauth:
        enabled: false

      vlselect:
        extraArgs:
          storageNode.tls: "true"
          storageNode.username: "vlogs"
          storageNode.password: "${random_password.vlogs_storage_node_pw.result}"
        ingress:
          enabled: true
          ingressClassName: nginx
          hosts:
            - name: vlselect.${var.ingress_apex}
              path:
                - /
              port: http
          tls:
            - secretName: cluster-tls
              hosts:
                - vlselect.${var.ingress_apex}
    YML
    ,yamlencode({
      storageNodes = concat([
        for vlogs_client in jsondecode(data.pxc_cloud_secrets.vlogs_clients.secrets_data) : vlogs_client.host
      ], ["vlogs.${var.ingress_apex}"]) # we cant go direct because extraargs tls sets it for all storage nodes
    })
  ]

  timeout = 1200
}


# also deploy database and alerting
# todo: refactor later into shared?
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
            - name: vlogs.${var.ingress_apex}
              path:
                - /
              port: http
          tls:
            - secretName: cluster-tls
              hosts:
                - vlogs.${var.ingress_apex}
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