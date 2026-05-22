from scenarios import *
import logging

logger = logging.getLogger(__name__)

def test_secondary_logging(get_test_env, secondary_scenario, get_k8s_secondary_api_v1):
    logger.info("secondary logging")
