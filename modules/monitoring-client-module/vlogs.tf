resource "random_password" "vlogs_pw" {
  length           = 16
  special          = false
}

resource "pxc_cloud_secret" "alertmanager_mon" {
  secret_name = "${data.pxc_cloud_self.self.stack_name}.${data.pxc_cloud_self.self.target_pve}-vlogs"
  secret_data = jsonencode({
    host = var.victorialogs_host
    k8s_stack_name = data.pxc_cloud_self.self.stack_name
    password = random_password.vlogs_pw.result
  })
  secret_type = "mon-vlogs-node"
}

resource "kubernetes_secret" "basic_auth_secret_vlogs" {
  type = "Opaque"
  metadata {
    name = "basic-auth-vlogs"
    namespace = kubernetes_namespace.mon_ns.metadata[0].name
  }
  data = {
    "auth" : "vlogs:${bcrypt(random_password.vlogs_pw.result)}"
  }
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
      server:
        ingress:
          annotations:
            "nginx.ingress.kubernetes.io/auth-type": "basic"
            "nginx.ingress.kubernetes.io/auth-secret": "basic-auth-vlogs"
            "nginx.ingress.kubernetes.io/auth-realm": thentication Required" 
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
            url: 
        # todo: source these from the shared module   
        config:
          alerts:
            groups:
              - name: LogAlerts
                type: vlogs
                rules:
                  - alert: HighErrorRate
                    expr: '(error OR exception) | stats by (kubernetes.pod_name) count() as total'
                    for: 1m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Errors found in {{ $labels.kubernetes_pod_name }}"
    YML
  ]

  timeout = 1200
}