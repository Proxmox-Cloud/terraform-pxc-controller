import logging
from fixtures import *
from pve_cloud_test.integration import integration_config

logger = logging.getLogger(__name__)


def test_setup_acme_certs(request, integration_config, vlogs_alerts_scenario):
    logger.info("test setup acme certs")
