variable "test_namespace" {
  type    = string
  default = "test-ns"
}

variable "test_dockerconfig" {
  type    = string
  default = "{\"auths\":{\"harbor.example.com\":{\"username\":\"robot\",\"password\":\"secret\"}}}"
}

run "secret_name_is_cluster_pull_secret" {
  command = plan

  assert {
    condition     = module.harbor_namespace_inject.secret.metadata[0].name == "cluster-pull-secret"
    error_message = "Secret name must be 'cluster-pull-secret' for the cloud controller to detect it"
  }
}

run "secret_type_is_dockerconfigjson" {
  command = plan

  assert {
    condition     = module.harbor_namespace_inject.secret.type == "kubernetes.io/dockerconfigjson"
    error_message = "Secret type must be 'kubernetes.io/dockerconfigjson' for docker registry authentication"
  }
}

run "secret_has_pod_inject_annotation" {
  command = plan

  assert {
    condition     = module.harbor_namespace_inject.secret.metadata[0].annotations["pve-cloud-pull-secret"] == "pod-inject"
    error_message = "Annotation 'pve-cloud-pull-secret' must be 'pod-inject' for the cloud controller to inject the secret"
  }
}

run "namespace_is_configurable" {
  command = plan

  variables {
    test_namespace = "custom-namespace"
  }

  assert {
    condition     = module.harbor_namespace_inject.secret.metadata[0].namespace == "custom-namespace"
    error_message = "Namespace must match the input variable"
  }
}

run "dockerconfigjson_data_field_is_set" {
  command = plan

  assert {
    condition     = module.harbor_namespace_inject.secret.data[".dockerconfigjson"] == var.test_dockerconfig
    error_message = "The .dockerconfigjson data field must be populated from the dockerconfig variable"
  }
}
