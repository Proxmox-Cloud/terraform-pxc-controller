resource "kubernetes_namespace" "pve_cloud_controller" {
  metadata {
    name = "pve-cloud-controller"
  }
}

data "pxc_cloud_self" "self" {}

data "pxc_cloud_file_secret" "bind_key" {
  secret_name = "internal.key"
}

data "pxc_cloud_file_secret" "patroni" {
  secret_name = "patroni.pass"
}

locals {
  cluster_vars = yamldecode(data.pxc_cloud_self.self.cluster_vars)

  k8s_stack_fqdn = "${data.pxc_cloud_self.self.stack_name}.${local.cluster_vars.pve_cloud_domain}"

  cluster_cert_entries = yamldecode(data.pxc_cloud_self.self.cluster_cert_entries)

  external_domains = yamldecode(data.pxc_cloud_self.self.external_domains)

  bind_dns_update_key = regex("secret\\s*\"([^\"]+)\"", data.pxc_cloud_file_secret.bind_key.secret)[0]

  pg_conn_str = "postgresql+psycopg2://postgres:${data.pxc_cloud_file_secret.patroni.secret}@${local.cluster_vars.pve_haproxy_floating_ip_internal}:5000/pve_cloud?sslmode=disable"

  default_exclude_mirror_namespaces = [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller", 
    "nginx-ingress", "ceph-csi", "pve-cloud-backup",
    "pve-cloud-monitoring-master", "pve-cloud-monitoring-client"
  ]

  default_exclude_tls_namespaces = [
    "default", "kube-system", "kube-public", 
    "kube-node-lease", "pve-cloud-controller", 
    "nginx-ingress", "ceph-csi", "pve-cloud-backup"
  ]
}

# try to fetch mirror credentials if available
data "pxc_cloud_secret" "harbor_mirror" {
  count = var.harbor_mirror_host != null ? 1 : 0
  secret_name = "${var.harbor_mirror_host}-mirror"
}

data "pxc_cloud_secret" "harbor_admin" {
  count = var.harbor_mirror_host != null ? 1 : 0
  secret_name = "${var.harbor_mirror_host}-admin"
}

locals {
  harbor_mirror_auth = var.harbor_mirror_host != null && data.pxc_cloud_secret.harbor_mirror[0].secret_data != "" ? jsondecode(data.pxc_cloud_secret.harbor_mirror[0].secret_data) : null
  harbor_admin_auth = var.harbor_mirror_host != null && data.pxc_cloud_secret.harbor_admin[0].secret_data != "" ? jsondecode(data.pxc_cloud_secret.harbor_admin[0].secret_data) : null
}

# optionally create mirror pull secret
resource "kubernetes_secret" "mirror_pull_secret" {
  count = var.harbor_mirror_host != null && local.harbor_mirror_auth != null ? 1 : 0
  metadata {
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
    name = "mirror-pull-secret"
  }
  data = {
    ".dockerconfigjson" = local.harbor_mirror_auth.dockerconfig
  }
  type = "kubernetes.io/dockerconfigjson"
}

resource "kubernetes_manifest" "ns_watcher" {
  manifest = yamldecode(<<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: pve-cloud-ns-watcher
      namespace: ${kubernetes_namespace.pve_cloud_controller.metadata[0].name}
      labels:
        app.kubernetes.io/name: pve-cloud-ns-watcher
        app.kubernetes.io/version: '${local.cloud_controller_version}'
    spec:
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: pve-cloud-ns-watcher
      template:
        metadata:
          labels:
            app.kubernetes.io/name: pve-cloud-ns-watcher
            app.kubernetes.io/version: '${local.cloud_controller_version}'
        spec:
          priorityClassName: system-cluster-critical
          containers:
            - name: watcher
              image: "${local.cloud_controller_image}:${local.cloud_controller_version}"
              imagePullPolicy: IfNotPresent
              env:
                - name: STACK_FQDN
                  value: '${local.k8s_stack_fqdn}'
                - name: PG_CONN_STR
                  value: '${local.pg_conn_str}'
                - name: EXCLUDE_TLS_NAMESPACES
                  value: '${join(",", concat(local.default_exclude_tls_namespaces, var.exclude_tls_namespaces))}'
      %{ if var.harbor_mirror_host != null && local.harbor_mirror_auth != null }
                - name: HARBOR_MIRROR_HOST
                  value: '${var.harbor_mirror_host}'
                # adm pod patch
                - name: HARBOR_MIRROR_PULL_SECRET_NAME
                  value: 'mirror-pull-secret'
      %{ endif }
              command: [ "ns-watcher" ]
  YAML
  )
}


resource "kubernetes_manifest" "pod_watcher" {
  # comment in on release
  count = var.harbor_mirror_host != null && local.harbor_admin_auth != null ? 1 : 0
  manifest = yamldecode(<<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: pve-cloud-pod-watcher
      namespace: ${kubernetes_namespace.pve_cloud_controller.metadata[0].name}
      labels:
        app.kubernetes.io/name: pve-cloud-pod-watcher
        app.kubernetes.io/version: '${local.cloud_controller_version}'
    spec:
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: pve-cloud-pod-watcher
      template:
        metadata:
          labels:
            app.kubernetes.io/name: pve-cloud-pod-watcher
            app.kubernetes.io/version: '${local.cloud_controller_version}'
        spec:
          containers:
            - name: watcher
              image: "${local.cloud_controller_image}:${local.cloud_controller_version}"
              imagePullPolicy: IfNotPresent
              env:
                - name: EXCLUDE_MIRROR_NAMESPACES
                  value: '${join(",", concat(local.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))}'
                - name: HARBOR_ADMIN_USER
                  value: '${local.harbor_admin_auth.full_name}'
                - name: HARBOR_ADMIN_PASSWORD
                  value:  '${local.harbor_admin_auth.secret}'
                - name: HARBOR_MIRROR_HOST
                  value: '${var.harbor_mirror_host}'
              command: [ "pod-watcher" ]
  YAML
  )
}


resource "kubernetes_config_map" "cluster_cert_entries" {
  metadata {
    name      = "cluster-conf"
    namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
  }

  data = {
    "cluster_cert_entries.json" = jsonencode(local.cluster_cert_entries)
    "external_domains.json" = jsonencode(local.external_domains)
  }
}


resource "kubernetes_manifest" "adm_deployment" {
  manifest = yamldecode(<<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: pve-cloud-adm
      namespace: ${kubernetes_namespace.pve_cloud_controller.metadata[0].name}
      labels:
        app.kubernetes.io/name: pve-cloud-adm
        app.kubernetes.io/version: '${local.cloud_controller_version}'
    spec:
      replicas: ${var.adm_controller_replicas}
      selector:
        matchLabels:
          app.kubernetes.io/name: pve-cloud-adm
      template:
        metadata:
          labels:
            app.kubernetes.io/name: pve-cloud-adm
            app.kubernetes.io/version: '${local.cloud_controller_version}'
        spec:
          priorityClassName: system-cluster-critical
          volumes:
            - name: pve-cloud-adm-tls
              secret:
                secretName: pve-cloud-adm-tls
                items:
                  - key: tls.crt
                    path: tls.crt
                  - key: tls.key
                    path: tls.key
            - name: cluster-conf
              configMap:
                name: cluster-conf
          containers:
            - name: adm
              image: "${local.cloud_controller_image}:${local.cloud_controller_version}"
              imagePullPolicy: IfNotPresent
              volumeMounts:
                - name: pve-cloud-adm-tls
                  mountPath: "/etc/tls"  
                  readOnly: true
                - name: cluster-conf
                  mountPath: "/etc/controller-conf"
                  raedOnly: true
              env:
                - name: LOG_LEVEL
                  value: '${var.log_level}'
                - name: PG_CONN_STR
                  value: '${local.pg_conn_str}'
                - name: EXCLUDE_MIRROR_NAMESPACES
                  value: '${join(",", concat(local.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))}'
      %{ if var.harbor_mirror_host != null && local.harbor_mirror_auth != null }
                - name: HARBOR_MIRROR_HOST
                  value: '${var.harbor_mirror_host}'
                - name: HARBOR_MIRROR_PULL_SECRET_NAME
                  value: 'mirror-pull-secret'
                # skopeo check
                - name: HARBOR_MIRROR_USER
                  value: '${local.harbor_mirror_auth.full_name}'
                - name: HARBOR_MIRROR_PASSWORD
                  value:  '${local.harbor_mirror_auth.secret}'
      %{ endif }
                - name: BIND_MASTER_IP
                  value: '${local.cluster_vars.bind_master_ip}'
                - name: BIND_DNS_UPDATE_KEY
                  value: '${local.bind_dns_update_key}'
                - name: INTERNAL_PROXY_FIP
                  value: '${local.cluster_vars.pve_haproxy_floating_ip_internal}' 
      %{ if var.route53_access_key_id != null && var.route53_secret_access_key != null && var.external_forwarded_ip != null }
                - name: ROUTE53_REGION
                  value: '${var.route53_region}'
                - name: ROUTE53_ACCESS_KEY_ID
                  value: '${var.route53_access_key_id}'
                - name: ROUTE53_SECRET_ACCESS_KEY
                  value: '${var.route53_secret_access_key}'
                - name: EXTERNAL_FORWARDED_IP
                  value: '${var.external_forwarded_ip}'     
      %{ endif}
      %{ if var.route53_endpoint_url != null }
                - name: ROUTE53_ENDPOINT_URL
                  value: '${var.route53_endpoint_url}'
      %{ endif}
              command: ["gunicorn"]
              args:
                - "-w"
                - "4"
                - "-b"
                - "0.0.0.0:443"
                - "--certfile=/etc/tls/tls.crt"
                - "--keyfile=/etc/tls/tls.key"
                - "pve_cloud_ctrl.adm:app"
              ports:
                - name: https
                  containerPort: 443
                  protocol: TCP
  YAML
  )
}

resource "kubernetes_manifest" "adm_service" {
  manifest = yamldecode(<<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: pve-cloud-adm
      namespace: ${kubernetes_namespace.pve_cloud_controller.metadata[0].name}
    spec:
      type: ClusterIP
      ports:
        - port: 443
          targetPort: https
          protocol: TCP
          name: https
      selector:
          app.kubernetes.io/name: pve-cloud-adm

  YAML
  )
}

resource "kubernetes_mutating_webhook_configuration" "adm_hook" {
  metadata {
    name = "pve-cloud-adm"
  }

  webhook {
    name = "pod.pve-cloud-adm.pve.cloud"

    client_config {
      service {
        name      = "pve-cloud-adm"
        namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
        path      = "/mutate-pod"
        port      = 443
      }
      ca_bundle = tls_self_signed_cert.ca.cert_pem
    }

    rule {
      api_groups   = [""]
      api_versions = ["v1"]
      operations   = ["CREATE"]
      resources    = ["pods"]
    }

    # hook patch for pods should not trigger for all namespaces
    namespace_selector {
      match_expressions {
        key = "kubernetes.io/metadata.name"
        operator = "NotIn"
        values = concat(local.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces)
      }
    }

    admission_review_versions = ["v1"]
    side_effects              = "None"
    failure_policy            = "Fail"
  }
  
  webhook {
    name = "ingress-dns.pve-cloud-adm.pve.cloud"

    client_config {
      service {
        name      = "pve-cloud-adm"
        namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
        path      = "/ingress-dns"
        port      = 443
      }
      ca_bundle = tls_self_signed_cert.ca.cert_pem
    }

    rule {
      api_groups   = ["networking.k8s.io"]
      api_versions = ["v1"]
      operations   = ["CREATE", "UPDATE", "DELETE"] # dynamic dns record 
      resources    = ["ingresses"]
    }

    # no selector - ingress dns for everything
    admission_review_versions = ["v1"]
    side_effects              = "None"
    failure_policy            = "Fail"
  }

  webhook {
    name = "namespace.pve-cloud-adm.pve.cloud"

    client_config {
      service {
        name      = "pve-cloud-adm"
        namespace = kubernetes_namespace.pve_cloud_controller.metadata[0].name
        path      = "/delete-namespace"
        port      = 443
      }
      ca_bundle = tls_self_signed_cert.ca.cert_pem
    }

    rule {
      api_groups   = [""]
      api_versions = ["v1"]
      resources    = ["namespaces"]
      operations   = ["DELETE"]
    }

    # no selector - ingress dns for everything
    admission_review_versions = ["v1"]
    side_effects              = "None"
    failure_policy            = "Fail"
  }

}


resource "kubernetes_manifest" "cron" {
  manifest = yamldecode(<<-YAML
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: pve-cloud-cron
      namespace: ${kubernetes_namespace.pve_cloud_controller.metadata[0].name}
      labels:
        app.kubernetes.io/name: pve-cloud-cron
        app.kubernetes.io/version: '${local.cloud_controller_version}'
    spec:
      schedule: "0 0 * * *"  # once every night
      jobTemplate:
        spec:
          backoffLimit: 0
          template:
            metadata:
              labels:
                app.kubernetes.io/name: pve-cloud-cron
                app.kubernetes.io/version: '${local.cloud_controller_version}'
            spec:
              restartPolicy: Never
              volumes:
                - name: cluster-conf
                  configMap:
                    name: cluster-conf
              containers:
                - name: cron
                  image: "${local.cloud_controller_image}:${local.cloud_controller_version}"
                  imagePullPolicy: IfNotPresent
                  volumeMounts:
                    - name: cluster-conf
                      mountPath: "/etc/controller-conf"
                      raedOnly: true
                  env:
                    - name: STACK_FQDN
                      value: '${local.k8s_stack_fqdn}'
                    - name: PG_CONN_STR
                      value: '${local.pg_conn_str}'
      %{ if var.harbor_mirror_host != null && local.harbor_mirror_auth != null }
                    - name: HARBOR_MIRROR_HOST
                      value: '${var.harbor_mirror_host}'
                    - name: HARBOR_MIRROR_PULL_SECRET_NAME
                      value: 'mirror-pull-secret'
      %{ endif }
                    - name: BIND_MASTER_IP
                      value: '${local.cluster_vars.bind_master_ip}'
                    - name: BIND_DNS_UPDATE_KEY
                      value: '${local.bind_dns_update_key}'
                    - name: INTERNAL_PROXY_FIP
                      value: '${local.cluster_vars.pve_haproxy_floating_ip_internal}' 
      %{ if var.route53_access_key_id != null && var.route53_secret_access_key != null && var.external_forwarded_ip != null }
                    - name: ROUTE53_REGION
                      value: '${var.route53_region}'
                    - name: ROUTE53_ACCESS_KEY_ID
                      value: '${var.route53_access_key_id}'
                    - name: ROUTE53_SECRET_ACCESS_KEY
                      value: '${var.route53_secret_access_key}'
                    - name: EXTERNAL_FORWARDED_IP
                      value: '${var.external_forwarded_ip}'     
      %{ endif}
      %{ if var.route53_endpoint_url != null }
                    - name: ROUTE53_ENDPOINT_URL
                      value: '${var.route53_endpoint_url}'
      %{ endif}
                    - name: EXCLUDE_MIRROR_NAMESPACES
                      value: '${join(",", concat(local.default_exclude_mirror_namespaces, var.exclude_mirror_namespaces))}'
                    - name: EXCLUDE_TLS_NAMESPACES
                      value: '${join(",", concat(local.default_exclude_tls_namespaces, var.exclude_tls_namespaces))}'
                  command: [ "cron" ]

  YAML
  )
}

