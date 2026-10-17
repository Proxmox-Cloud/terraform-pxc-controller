# Agent Instructions

For instructions on how to execute integration tests, read the pxc-integration (Proxmox Cloud Integration Testing) skill.

## Submodules (`modules/`)

- **external-acme-tls-csr** — Generates the private key and CSR (`pxc_external_acme_tls`) for obtaining TLS certs from an external ACME issuer.
- **external-pxc-controller** — Deploys the controller stack into an external (non-Proxmox) Kubernetes cluster, including its own locally signed CA and server certs for the admission webhook.
- **harbor-cluster-robot** — Creates a Harbor robot account with configurable project/registry permissions for cluster-wide access (e.g. image pull).
- **harbor-mirror-projects** — Sets up harbor mirror/caching infrastructure: projects + registry pull-through caches for Docker Hub, Quay, GitHub, k8s.io, AWS ECR, plus a helm mirror project and robot accounts, exposed as cloud secrets for the controller.
- **harbor-namespace-inject** — Writes the docker pull secret (`kubernetes.io/dockerconfigjson`) into a given namespace so the controller can patch pods to pull via harbor.
- **monitoring-client-module** — Per-cluster monitoring agent: kube-prometheus-stack, vmalert, vlogs helm releases, alertmanager→gotify bridge and related cloud secrets.
- **monitoring-master-stack** — Central (master) monitoring stack: kube-prometheus-stack, vmalert, vlogs + vlogs ML, gotify master app and karma dashboard, aggregating all client clusters.
- **monitoring-shared** — Shared monitoring components: graphite exporter deployment for PVE node metrics, ceph access, and VM inventory exposure for other clouds.
- **multi-cloud-gw** — Multi-cloud gateway: gateway deployment + service/ingress that federates peers across clouds via shared multi-cloud tokens, bind keys and discovery secrets.

