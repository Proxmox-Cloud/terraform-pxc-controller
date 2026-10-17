import pytest
from pve_cloud_test.terraform import apply_integration, destroy_integration


@pytest.fixture(scope="session")
def vlogs_alerts_scenario(integration_config):
    scenario_name = "vlogs-alerts"

    kubeconfig_path, _, v1, namespace = integration_config

    extra_apply_env = { "TF_VAR_vcluster_config_path": kubeconfig_path }

    apply_integration(scenario_name, extra_apply_env)

    yield

    destroy_integration(scenario_name, extra_apply_env)
