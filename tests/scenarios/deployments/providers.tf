

ephemeral "pxc_kubeconfig" "kubeconfig" {}

locals {
  kubeconfig = yamldecode(ephemeral.pxc_kubeconfig.kubeconfig.config)
  registries = jsondecode(ephemeral.pxc_kubeconfig.kubeconfig.registries)
}

provider "kubernetes" {
  client_certificate = base64decode(local.kubeconfig.users[0].user.client-certificate-data)
  client_key = base64decode(local.kubeconfig.users[0].user.client-key-data)
  host = local.kubeconfig.clusters[0].cluster.server
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster.certificate-authority-data)
}

provider "helm" {
  kubernetes = {
    client_certificate = base64decode(local.kubeconfig.users[0].user.client-certificate-data)
    client_key = base64decode(local.kubeconfig.users[0].user.client-key-data)
    host = local.kubeconfig.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster.certificate-authority-data) 
  }
  
  registries = [ 
    for r in local.registries : {
      url = "oci://${r.harbor_host}"
      username = r.full_name
      password = r.secret
    }
  ]
}

# for reading worker ips for metrics exporter on pve
provider "dns" {
  update {
    server = local.test_pve_conf["cloud_inventory"]["bind_master_ip"]
  }
}

## 