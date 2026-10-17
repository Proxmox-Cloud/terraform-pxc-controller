# Agent Instructions

The root terraform module deploys the Proxmox Cloud controller on Kubernetes: controller/admission deployments, namespace & pod watchers, DNS sync cron job, init job, and cluster-admin RBAC binding. Handles internal ingress DNS (PVE BIND), optional external ingress DNS (Route53 via `route53_*` vars), TLS certificate injection into namespaces (CA + `cluster-tls` secret in `tls.tf`), and optional harbor mirror-credentials injection (pull secret, `exclude_mirror_namespaces`).

## Testing

Ignore the tests under `tests/e2e` and `tests/scenarios` these are tests executed by real developers on a running test environment you dont have access to.

For running tests you should strictly focus on the integration tests located under `tests/integration`. Always run tests to validate your changes!

To run tests you have to do the following:

1. First always run the setup bash script with `source tests/setup-integration-env.sh`. This sets up the python enviroment and any needed dependencies.
2. Run the integration tests:
```bash
# run the entire integration testing suite
pytest -s tests/integration/

# run specific tests
pytest -s tests/integration/test_modules.py::test_vlogs_alerting_rules
```

### Debugging

When a test fails or when you want to analyze, you can run it again but with the `--skip-cleanup` flag passed to `pytest`. This will cause the integration infrastructure to be kept for you to inspect it and draw conclusions.

Use the following snippet to gain `kubectl` access to the integration test infrastructure / deployments:

```bash
agent-kubeconfig > .agent-kubeconfig.yml
export KUBECONFIG=$(pwd)/.agent-kubeconfig.yml

# ... use any kubectl commands need to analyze / test
INTEGRATION_NS=$(cat .itgr-test-ns)
kubectl get pods -n $INTEGRATION_NS # for example

```

Each integration test run generates its own namespace, fetch this from the `pytest ... --skip-cleanup` shell log, it will also be written to the local file `.itgr-test-ns` in the current workdir by the test itself.

## Writing Tests

Features you create should make use of the integration testing library. You should create integration tests and execute them to validate your changes!

To understand how to write them you may analyze the existing tests in `tests/integration`.

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

