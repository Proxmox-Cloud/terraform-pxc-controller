# fetch multi cloud peers, since this is the master stack we 
# bundle all alerts here
# todo: this needs special -target apply on init because of terraform retardedness
# refactor into own datasource. also fix in monitoring-client-module
data "pxc_cloud_secret" "mc_discovery" {
  secret_name = "mc_discovery"
}

locals {
  mc_peers_set = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? toset(jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data).peers) : toset([])
  mc_token = data.pxc_cloud_secret.mc_discovery.secret_data != "" ? jsondecode(data.pxc_cloud_secret.mc_discovery.secret_data).token : ""
}
