# Monitoring Master Stack

This will host uis, alerting configs and exporters for montoring related to your proxmox cloud.

Contains a karma ui instance for visualizing alerts aswell as a gotify application for critical notifications.

## Proxmox backup server

If you use a proxmox backup server you can configure the gotify in this stack as a target for notifications.

For that create a new app in the gotify ui, simply adding `https://gotify.your.domain` as target and copying the token from the ui.

Create a matcher for error severities and point it to your gotify instance.

## AWX

AWX supports gotify only via the generic webhook.

Again create an app inside gotify for your awx and copy the token. For the notification inside the awx ui set `https://gotify.yourdomain.tech/message?token=YOUR_TOKEN_HERE` as target url.

You need to modify the message templates by setting the slider `Customize messages...`. For the error message set the value to `{ "title": "Job {{ job.name }} failed!", "message": "Job {{ job.id }} failed, playbook: {{ job.playbook }}, project: {{ job.summary_fields.project.name }}." }`.

Then inside the projects you want notifications enable failure notifications for this template. The test notification doesnt work as its not compatible with gotifys format.