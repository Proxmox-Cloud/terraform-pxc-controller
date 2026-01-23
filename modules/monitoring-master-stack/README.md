# Monitoring Master Stack

This will host uis, alerting configs and exporters for montoring related to your proxmox cloud.

Contains a karma ui instance for visualizing alerts aswell as a gotify application for notifications.

## Proxmox cluster metrics

In order to monitor proxmox metrics, we need to configure an entry in `tcp_proxies` of our kubespray inventory file like this:

```yaml
tcp_proxies:
  # pod that pve will send graphite metrics to, and which exports them as prometheus metrics
  - proxy_name: graphite-exporter
    haproxy_port: # unique free port on our haproxy
    node_port: 30109 # hardcoded since its cluster scoped
```

The `haproxy_port` we defined has to be set to the `graphite_exporter_port` terraform variable.

This will cause the module to setup a graphite exporter on your target proxmox cluster and point it to that port on the proxy, which in turn will
send metrics to the graphite exporter deployed in k8s.