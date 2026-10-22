variable "vcluster_config_path" {
  type = string
}

variable "integration_ns" {
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

resource "helm_release" "vlogs" {
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart = "victoria-logs-single"
  version = "0.13.9"
  name = "vlogs"
  namespace = var.integration_ns

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

  values = [
    <<-YML
      server:
        datasource:
          url: "http://vlogs-victoria-logs-single-server:9428"
    YML
  ]
}
