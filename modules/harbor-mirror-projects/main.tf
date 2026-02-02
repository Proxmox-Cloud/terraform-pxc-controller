# google
resource "harbor_registry" "github_cache" {
  provider_name = "docker-registry"
  name = "github ghcr"
  endpoint_url = "https://ghcr.io"
}

resource "harbor_project" "github_cache" {
  name        = "github-cache"
  registry_id = harbor_registry.github_cache.registry_id
}

# aws
resource "harbor_registry" "aws_ecr_cache" {
  provider_name = "docker-registry"
  name = "aws ecr"
  endpoint_url = "https://public.ecr.aws"
}

resource "harbor_project" "aws_ecr_cache" {
  name        = "aws-ecr-cache"
  registry_id = harbor_registry.aws_ecr_cache.registry_id
}

# quay
resource "harbor_registry" "quay_cache" {
  provider_name = "docker-registry"
  name = "quay"
  endpoint_url = "https://quay.io"
}

resource "harbor_project" "quay_cache" {
  name        = "quay-cache"
  registry_id = harbor_registry.quay_cache.registry_id
}

# docker hub
resource "harbor_registry" "docker_hub_cache" {
  provider_name = "docker-hub"
  name = "docker hub"
  endpoint_url = "https://hub.docker.com"
}

resource "harbor_project" "docker_hub_cache" {
  name        = "docker-hub-cache"
  registry_id = harbor_registry.docker_hub_cache.registry_id
}

# full mirror repository, here our proxmox cloud controller will via harbor
# webhooks create fully standalone mirrored images
resource "harbor_project" "cloud_mirror" {
  name        = "cloud-mirror"
}

# pull access to caches and mirror repositories
resource "harbor_robot_account" "cloud_mirror" {
  name        = "cloud-mirror-robot"
  description = "robot account for cache / mirror pulls"
  level       = "system"

  # allow pull
  permissions {
    kind = "project"
    namespace = harbor_project.github_cache.name
    access {
      resource = "repository"
      action = "pull"
      effect = "allow"
    }
  }

  permissions {
    kind = "project"
    namespace = harbor_project.aws_ecr_cache.name
    access {
      resource = "repository"
      action = "pull"
      effect = "allow"
    }
  }

  permissions {
    kind = "project"
    namespace = harbor_project.quay_cache.name
    access {
      resource = "repository"
      action = "pull"
      effect = "allow"
    }
  }

  permissions {
    kind = "project"
    namespace = harbor_project.docker_hub_cache.name
    access {
      resource = "repository"
      action = "pull"
      effect = "allow"
    }
  }

  permissions {
    kind = "project"
    namespace = harbor_project.cloud_mirror.name
    access {
      resource = "repository"
      action = "pull"
      effect = "allow"
    }
  }
}

# create pxc cloud secret from it
resource "pxc_cloud_secret" "cloud_mirror" {
  secret_name = "${local.harbor_host}-mirror"
  secret_data = jsonencode({
    full_name = harbor_robot_account.cloud_mirror.full_name
    secret = harbor_robot_account.cloud_mirror.secret
    auth_b64 = base64encode("${harbor_robot_account.cloud_mirror.full_name}:${harbor_robot_account.cloud_mirror.secret}")
    dockerconfig = <<-CFG
      {
              "auths": {
                      "${local.harbor_host}": {
                              "auth": "${base64encode("${harbor_robot_account.cloud_mirror.full_name}:${harbor_robot_account.cloud_mirror.secret}")}"
                      }
              }
      }
    CFG
  })
}

# generic cloud admin robot account
resource "harbor_robot_account" "cloud_admin" {
  name        = "cloud-admin-robot"
  description = "cloud admin robot account"
  level       = "system"

  permissions {
    kind = "project"
    namespace = "*"
    access {
      resource = "repository"
      action = "pull"
      effect = "allow"
    }
    access {
      resource = "repository"
      action = "push"
      effect = "allow"
    }
  }
}


resource "pxc_cloud_secret" "cloud_admin" {
  secret_name = "${local.harbor_host}-admin"
  secret_data = jsonencode({
    full_name = harbor_robot_account.cloud_admin.full_name
    secret = harbor_robot_account.cloud_admin.secret
    auth_b64 = base64encode("${harbor_robot_account.cloud_admin.full_name}:${harbor_robot_account.cloud_admin.secret}")
    dockerconfig = <<-CFG
      {
              "auths": {
                      "${local.harbor_host}": {
                              "auth": "${base64encode("${harbor_robot_account.cloud_admin.full_name}:${harbor_robot_account.cloud_admin.secret}")}"
                      }
              }
      }
    CFG
  })
}

