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

## Proxmox backup server

If you use a proxmox backup server you can configure the gotify in this stack as a target for notifications.

For that create a new app in the gotify ui, simply adding `https://gotify.your.domain` as target and copying the token from the ui.

Create a matcher for error severities and point it to your gotify instance.

## AWX

AWX supports gotify only via the generic webhook.

Again create an app inside gotify for your awx and copy the token. For the notification inside the awx ui set `https://gotify.yourdomain.tech/message?token=YOUR_TOKEN_HERE` as target url.

You need to modify the message templates by setting the slider `Customize messages...`. For the error message set the value to `{ "title": "Job {{ job.name }} failed!", "message": "Job {{ job.id }} failed, playbook: {{ job.playbook }}, project: {{ job.summary_fields.project.name }}." }`.

Then inside the projects you want notifications enable failure notifications for this template. The test notification doesnt work as its not compatible with gotifys format.