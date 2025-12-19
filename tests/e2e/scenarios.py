import pytest
import yaml
from proxmoxer import ProxmoxAPI
import paramiko
import base64
import os
import re
import random
import string
from pve_cloud_test.terraform import apply, destroy
from kubernetes import client, config
import tempfile
import logging
import redis
from pve_cloud_test.cloud_fixtures import *
from pve_cloud_test.k8s_fixtures import *
from pve_cloud_test.tdd_watchdog import get_ipv4
import boto3
import dns.resolver
import time

logger = logging.getLogger(__name__)

# is called by controller fixture, other tests include get_moto fixture
def init_moto(proxmox, get_test_env):
  # get the ip of our worker node
  worker = None
  for node in proxmox.nodes.get():
    node_name = node["node"]

    if node["status"] == "offline":
      logger.info(f"skipping offline node {node_name}")
      continue
    
    for qemu in proxmox.nodes(node_name).qemu.get():
      if "tags" in qemu and 'pytest-k8s' in qemu["tags"] and 'worker' in qemu["tags"].split(";"):
        worker = qemu
        break

  assert worker

  resolver = dns.resolver.Resolver()
  resolver.nameservers = [get_test_env['pve_test_cloud_inv']['bind_master_ip']]

  ddns_answer = resolver.resolve(f"{worker['name']}.{get_test_env['pve_test_cloud_domain']}")
  ddns_ips = [rdata.to_text() for rdata in ddns_answer]

  assert ddns_ips
  
  # add zones testing zones to moto server
  client = boto3.client(
    "route53",
    region_name="us-east-1",
    endpoint_url=f"http://{ddns_ips[0]}:30500",
    aws_access_key_id="test",
    aws_secret_access_key="test"
  )

  existing_zones = client.list_hosted_zones()["HostedZones"]

  assert existing_zones is not None

  test_deployment_zone_exists = False
  for zone in existing_zones:
    if zone["Name"] == get_test_env['pve_test_deployments_domain'] + ".":
      test_deployment_zone_exists = True
      break
  
  if not test_deployment_zone_exists:
    create_resp = client.create_hosted_zone(
      Name=get_test_env['pve_test_deployments_domain'] + ".",
      CallerReference="pve-test-deployments-domain"
    )

  list_resp = client.list_hosted_zones()

  assert list_resp["HostedZones"]

  return client


@pytest.fixture(scope="session")
def get_moto_client(get_test_env, get_proxmoxer, controller_scenario):
  proxmox = get_proxmoxer
  # get the ip of our worker node
  worker = None
  for node in proxmox.nodes.get():
    node_name = node["node"]

    if node["status"] == "offline":
      logger.info(f"skipping offline node {node_name}")
      continue
    
    for qemu in proxmox.nodes(node_name).qemu.get():
      if "tags" in qemu and 'pytest-k8s' in qemu["tags"] and 'worker' in qemu["tags"].split(";"):
        worker = qemu
        break

  assert worker

  resolver = dns.resolver.Resolver()
  resolver.nameservers = [get_test_env['pve_test_cloud_inv']['bind_master_ip']]

  ddns_answer = resolver.resolve(f"{worker['name']}.{get_test_env['pve_test_cloud_domain']}")
  ddns_ips = [rdata.to_text() for rdata in ddns_answer]

  assert ddns_ips
  
  # add zones testing zones to moto server
  client = boto3.client(
    "route53",
    region_name="us-east-1",
    endpoint_url=f"http://{ddns_ips[0]}:30500",
    aws_access_key_id="test",
    aws_secret_access_key="test"
  )

  return client


# needs the set_pve_cloud_auth fixture for os.environ variables
@pytest.fixture(scope="session")
def controller_scenario(request, get_proxmoxer, get_test_env, set_pve_cloud_auth, get_k8s_api_v1): 
  scenario_name = "controller"

  if os.getenv("TDDOG_LOCAL_IFACE"):
    # get version for image from redis
    r = redis.Redis(host='localhost', port=6379, db=0)
    local_build_ctrl_version = r.get("version.pve-cloud-controller")

    if local_build_ctrl_version:
      logger.info(f"found local version {local_build_ctrl_version.decode()}")
      
      # set controller base image
      os.environ["TF_VAR_cloud_controller_image"] = f"{get_ipv4(os.getenv('TDDOG_LOCAL_IFACE'))}:5000/pve-cloud-controller"
      os.environ["TF_VAR_cloud_controller_version"] = local_build_ctrl_version.decode()
    else:
      logger.warning(f"did not find local build pve cloud controller version even though TDDOG_LOCAL_IFACE env is defined")

  if not request.config.getoption("--skip-apply"):
    apply("pxc-controller", scenario_name, get_k8s_api_v1, True, True) # always upgrade to get tdd build provider and inject custom e2e rc

  # init aws moto mock server
  init_moto(get_proxmoxer, get_test_env)

  yield 

  if not request.config.getoption("--skip-cleanup"):
    destroy(scenario_name)
