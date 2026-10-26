variable "vcluster_config_path" {
  type = string
}

variable "integration_ns" {
  type = string
}

variable "pytest_cwd" {
  type = string
}

provider "kubernetes" {
  config_path = var.vcluster_config_path
}

provider "helm" {
  kubernetes = {
    config_path = var.vcluster_config_path
  }
}

# Render the vlogs alert rules template from the monitoring-shared module
data "template_file" "vlogs_alert_rules" {
  template = file("${var.pytest_cwd}/modules/monitoring-shared/vlogs-alert-rules.yaml.tftpl")
  vars = {
    error_base_filter       = "!level: i(info) AND (i(panic) OR i(exception) OR i(fatal) OR i(critical) OR i(error) OR i(segfault))"
    k8s_ns_filter           = "kubernetes.pod_namespace:*"
    k8s_alert_level         = "ALL"
    k8s_ns_specific         = jsonencode({})
    journald_service_filter = "_SYSTEMD_UNIT:*"
    journald_service_specific = jsonencode({})
  }
}

resource "helm_release" "vlogs" {
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart = "victoria-logs-single"
  version = "0.13.9"
  name = "vlogs"
  namespace = var.integration_ns
  upgrade_install = true
  timeout = 120

  # values = [
  #   <<-YML
  #     server:
  #       securityContext:
  #         seccompProfile:
  #           type: RuntimeDefault
  #       podSecurityContext:
  #         seccompProfile:
  #           type: RuntimeDefault
  #   YML
  # ]

}

resource "helm_release" "vmalert" {
  repository ="https://victoriametrics.github.io/helm-charts/"
  chart = "victoria-metrics-alert"
  version = "0.47.0"
  name = "vmalert"
  namespace = var.integration_ns
  upgrade_install = true
  timeout = 120

  values = [
    <<-YML
      server:
        datasource:
          url: "http://vlogs-victoria-logs-single-server:9428"
        rules:
          yaml: |
            ${data.template_file.vlogs_alert_rules.rendered}
        extraArgs:
          notifier.blackhole: "true"
    YML
  ]
}
