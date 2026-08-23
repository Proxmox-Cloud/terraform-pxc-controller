# terraform-pxc-controller

## Main module (repo root)

Deploys the Proxmox Cloud controller on Kubernetes: controller/admission deployments, namespace & pod watchers, DNS sync cron job, init job, and cluster-admin RBAC binding. Handles internal ingress DNS (PVE BIND), optional external ingress DNS (Route53 via `route53_*` vars), TLS certificate injection into namespaces (CA + `cluster-tls` secret in `tls.tf`), and optional harbor mirror-credentials injection (pull secret, `exclude_mirror_namespaces`).

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

## Testing (E2E)

`tests/e2e/fixtures.py` defines session-scoped **cloud fixtures** (`@cloud_fixture(*tags)` from `pve_cloud_test.cloud_fixtures`). Each fixture runs `terraform apply` (teardown: `terraform destroy`) on one scenario dir in `tests/scenarios/` against the test cloud, connected through the custom `pxc` terraform provider. Dependency chain:

```
controller_scenario -> deployments_scenario -> secondary_scenario
              \-> harbor_scenario
k0s_edge_scenario (independent, targets the k0s cluster)
```

`--fixture-tags a,b` executes only fixtures whose tags intersect a,b; all other cloud fixtures are skipped as no-ops (the test logic still runs against already deployed infra). `--skip-fixture-tags` is the inverse, `--skip-fixtures` skips all fixtures. `--skip-cleanup` keeps the applied state (skips `terraform destroy`).

### Fixtures, tags, and scenarios executed

| Fixture | Tags | Scenario applied | Covers |
|---|---|---|---|
| `controller_scenario` | `controller` | `tests/scenarios/controller` | core root module on the primary kubespray cluster (controller/admission, DNS sync cron, init job, RBAC, TLS injection, route53 via moto), `modules/multi-cloud-gw` (peer = local http mock on :8888), moto Route53 mock (nodeport 30500) + hosted zone init, harbor helm release (via `pxc_helm_mirror`), `pxc_cloud_age_secret` + `pxc_dns_cname_record` provider resources; cleans up failed startup cronjobs |
| `deployments_scenario` | `deployments` | `tests/scenarios/deployments` | 3x bitnami nginx helm releases (random self-signed host, `external-example` external host, `nginx-ns-delete-test` namespace), `modules/monitoring-master-stack` + karma ingress, proxy-protocol whitelist nginx (`nginx-test-prxy-proto`), fio PVC/pod; apply wrapped in the mc-gw http mock |
| `harbor_scenario` | `harbor` | `tests/scenarios/harbor`, then re-applies `controller` | `modules/harbor-mirror-projects`; controller re-applied so it picks up the harbor secrets created by discovery |
| `secondary_scenario` | `secondary` | `tests/scenarios/secondary` | on the secondary kubespray cluster: root module + `modules/monitoring-client-module`, `pxc_pve_inventory`/`pxc_cloud_self` data sources; on the external `pytest-external` stack: `modules/external-acme-tls-csr` + `modules/external-pxc-controller`; re-applies `deployments` on primary so master monitoring registers the new client |
| `k0s_edge_scenario` | `k0s`, `k0s-edge` | `tests/scenarios/k0s-edge` | `modules/external-pxc-controller` + `modules/external-acme-tls-csr` on the k0s cluster (ext hosts inventory) — validates `pxc` provider connect/init against k0s |

Note: `get_moto_client` (plain session fixture, no tag) connects a boto3 Route53 client to the moto mock deployed by `controller_scenario`.

### Tests and required fixture tags

`tests/e2e/test_modules.py` — pass the fixture tag of the scenario you changed; all other scenarios stay skipped:

| Test | Fixture tags to pass | What it validates |
|---|---|---|
| `test_adm_pod_creation` | `controller` | admission controller allows namespace + pod creation; no new controller pod restarts |
| `test_cloud_cron_execution` | `controller` | manual `pve-cloud-cron` job trigger completes successfully |
| `test_ingress_cluster_cert_block` | `controller` | webhook rejects ingress host not covered by the cluster certificate (500 + message), allows covered host |
| `test_delete_ingress` | `controller` | ingress deletion removes the record from bind and moto Route53 |
| `test_update_ingress` | `controller` | ingress host change updates bind record (new added, old removed) and POSTs to mc-gw `/ingress-ddns-update` (http mock on :8888) |
| `test_mc_gw_ingress_update` | `controller` | mc-gw `/ingress-ddns-update` ADD/DELETE creates/removes bind records (token `DEMO-MC-TOKEN`) |
| `test_mc_gw_acme_update` | `controller` | mc-gw `/get-acme-configs` returns 200 |
| `test_mc_gw_get_acme_acc` | `controller` | mc-gw `/get-acme-account` responds |
| `test_mc_gw_get_alertmanagers` | `controller` | mc-gw `/get-client-alertmanagers` returns 200 |
| `test_mc_gw_get_vclients` | `controller` | mc-gw `/get-victoria-clients` returns 200 |
| `test_ingress_connectivity` | `deployments` | A record resolves to the haproxy floating IP; 443 cert served is issued by `nginx-ca` (self-signed cert injection) |
| `test_ingress_dns` | `deployments` | bind record created for the random nginx test ingress |
| `test_proxy_proto_403` | `deployments` | `whitelist-source-range` ingress returns 403 via proxy protocol |
| `test_external_ingress_dns` | `deployments` | moto Route53 contains `external-example` host but not the internal-only random host |
| `test_delete_namespace_ingress_hook` | `deployments` | namespace deletion removes its ingress bind records |
| `test_monitoring_alert_rules` | `deployments` | alertmanager API: no unexpected critical alerts firing |
| `test_harbor_mirror_superficial` | `harbor` | pod image rewritten to the harbor mirror host (pull-secret injection + mirror patching) |
| `test_secondary_logging` | `secondary` | placeholder (empty) |
| `test_external_acme_tls` | `secondary` | placeholder (empty) |
| `test_k0s_provider_connect` | `k0s` (or `k0s-edge`) | `pxc` provider connects/initializes the k0s cluster (scenario deploys external controller + ACME CSR modules there) |

### Example invocations

```bash
# controller / admission / mc-gw changes
pytest -s tests/e2e/test_modules.py::test_adm_pod_creation --skip-cleanup --fixture-tags controller

# ingress dns / tls injection / monitoring master changes
pytest -s tests/e2e/test_modules.py::test_ingress_dns --skip-cleanup --fixture-tags deployments

# harbor mirror projects changes
pytest -s tests/e2e/test_modules.py::test_harbor_mirror_superficial --skip-cleanup --fixture-tags harbor

# secondary cluster / external controller / acme csr changes
pytest -s tests/e2e/test_modules.py::test_external_acme_tls --skip-cleanup --fixture-tags secondary

# k0s provider / external k0s stack changes
pytest -s tests/e2e/test_modules.py::test_k0s_provider_connect --skip-cleanup --fixture-tags k0s

# re-run test logic only, against fully deployed infra
pytest -s tests/e2e/test_modules.py::test_ingress_dns --skip-cleanup --skip-fixtures
```
