# do the multi cloud discovery
data "pxc_cloud_secret" "mc_discovery" {
  secret_name = "mc_discovery"
}

locals {
  mc_peers_set = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? toset(jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data).peers) : toset([])
  mc_token = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data).token : ""
}
