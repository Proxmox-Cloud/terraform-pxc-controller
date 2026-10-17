import logging

from fixtures import *
from pve_cloud_test.integration import integration_config

logger = logging.getLogger(__name__)


def test_vlogs_alerting_rules(request, integration_config, vlogs_alerts_scenario):
    logger.info("test setup acme certs")

    kubeconfig_path, k8s_client, v1, namespace = integration_config
