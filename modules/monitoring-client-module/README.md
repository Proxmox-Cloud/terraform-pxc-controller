# Monitoring Client Module

This is intended to be installed in client kubernetes clusters that should be plugged into the main monitoring.

On the first apply you have to first target the discovery secret datasource by adding `-target=module.XYZ.data.pxc_cloud_secret.mc_discovery`.

## Proxmox cluster monitoring

If the kubernetes cluster where you install this module is on a different proxmox cluster than where the master monitoring module of your cloud is installed to, you can set the variables `monitor_proxmox_cluster` to cause the stack to monitor your proxmox cluster.