import logging

import requests

from fixtures import *
from pve_cloud_test.integration import integration_config

logger = logging.getLogger(__name__)


def test_vlogs_alerting_rules(request, integration_config, vlogs_alerts_scenario):
    logger.info("test setup acme certs")

    kubeconfig_path, k8s_client, v1, namespace = integration_config

    # Use the forward_ports_local_addr context manager to forward vmalert port
    # and validate that the alerts are loaded correctly
    from pve_cloud_test.integration import forward_ports_local_addr

    # Find the vmalert pod
    pods = v1.list_namespaced_pod(namespace)
    vmalert_pod = None
    for pod in pods.items:
        if "vmalert" in pod.metadata.name:
            vmalert_pod = pod
            break

    assert vmalert_pod is not None, "vmalert pod not found in namespace"

    # Forward the vmalert port (8880) and check the /api/v1/rules endpoint
    # The ports parameter expects a list of strings in "local:container" format
    with forward_ports_local_addr(
        target_name=vmalert_pod.metadata.name,
        namespace=namespace,
        ports=["8880:8880"],
        target_type="pod",
        kubeconfig_path=kubeconfig_path,
    ) as loopback_addr:
        # Wait a bit for the port forward to establish
        import time
        time.sleep(3)

        # Check the health endpoint
        health_url = f"http://{loopback_addr}:8880/-/healthy"
        response = requests.get(health_url, timeout=10)
        assert response.status_code == 200, f"vmalert health check failed: {response.text}"
        assert "VictoriaMetrics is Healthy" in response.text

        # Check the rules endpoint to verify all alert groups are loaded
        rules_url = f"http://{loopback_addr}:8880/api/v1/rules"
        response = requests.get(rules_url, timeout=10)
        assert response.status_code == 200, f"Failed to get rules: {response.text}"

        rules_data = response.json()
        assert rules_data["status"] == "success", "Rules API returned non-success status"

        groups = rules_data["data"]["groups"]
        group_names = [g["name"] for g in groups]

        # Verify all expected alert groups are present
        expected_groups = [
            "Journald Log Base Alerts",
            "Journald Log Volume Alerts",
            "K8S Log Base Alerts",
            "K8S Log Volume Alerts",
        ]

        for expected_group in expected_groups:
            assert expected_group in group_names, f"Expected group '{expected_group}' not found in {group_names}"

        # Verify the rules are healthy
        for group in groups:
            assert group["type"] == "vlogs", f"Group {group['name']} is not a vlogs type"
            for rule in group["rules"]:
                assert rule["health"] == "ok", f"Rule {rule['name']} in group {group['name']} is not healthy"

        logger.info(f"Successfully validated {len(groups)} alert groups: {group_names}")
