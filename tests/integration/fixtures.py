import pytest
from pve_cloud_test.cloud_fixtures import cloud_fixture
from pve_cloud_test.terraform import apply_integration, destroy_integration


@cloud_fixture("vlogs")
def vlogs_alerts_scenario(request, integration_config):
    scenario_name = "vlogs-alerts"

    kubeconfig_path, _, v1, namespace = integration_config

    extra_apply_env = {
        "TF_VAR_vcluster_config_path": kubeconfig_path,
        "TF_VAR_integration_ns": namespace,
    }

    apply_integration(scenario_name, v1, extra_apply_env)

    yield

    destroy_integration(scenario_name, extra_apply_env)
