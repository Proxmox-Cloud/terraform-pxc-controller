import logging
import os
import random
import string
import time

import boto3
import dns.resolver
import paramiko
import pytest
import redis
import yaml
from kubernetes import client, config
from proxmoxer import ProxmoxAPI
from pve_cloud_test.cloud_fixtures import *
from pve_cloud_test.k8s_fixtures import *
from pve_cloud_test.tdd_watchdog import get_ipv4
from pve_cloud_test.terraform import apply, destroy

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
            if (
                "tags" in qemu
                and "pytest-k8s" in qemu["tags"]
                and "worker" in qemu["tags"].split(";")
            ):
                worker = qemu
                break

    assert worker

    resolver = dns.resolver.Resolver()
    resolver.nameservers = [get_test_env["pve_test_cloud_inv"]["bind_master_ip"]]

    ddns_answer = resolver.resolve(
        f"{worker['name']}.{get_test_env['pve_test_cloud_domain']}"
    )
    ddns_ips = [rdata.to_text() for rdata in ddns_answer]

    assert ddns_ips

    # add zones testing zones to moto server
    client = boto3.client(
        "route53",
        region_name="us-east-1",
        endpoint_url=f"http://{ddns_ips[0]}:30500",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )

    existing_zones = client.list_hosted_zones()["HostedZones"]

    assert existing_zones is not None

    test_deployment_zone_exists = False
    for zone in existing_zones:
        if zone["Name"] == get_test_env["pve_test_deployments_domain"] + ".":
            test_deployment_zone_exists = True
            break

    if not test_deployment_zone_exists:
        create_resp = client.create_hosted_zone(
            Name=get_test_env["pve_test_deployments_domain"] + ".",
            CallerReference="pve-test-deployments-domain",
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
            if (
                "tags" in qemu
                and "pytest-k8s" in qemu["tags"]
                and "worker" in qemu["tags"].split(";")
            ):
                worker = qemu
                break

    assert worker

    resolver = dns.resolver.Resolver()
    resolver.nameservers = [get_test_env["pve_test_cloud_inv"]["bind_master_ip"]]

    ddns_answer = resolver.resolve(
        f"{worker['name']}.{get_test_env['pve_test_cloud_domain']}"
    )
    ddns_ips = [rdata.to_text() for rdata in ddns_answer]

    assert ddns_ips

    # add zones testing zones to moto server
    client = boto3.client(
        "route53",
        region_name="us-east-1",
        endpoint_url=f"http://{ddns_ips[0]}:30500",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )

    return client


# needs the set_pve_cloud_auth fixture for os.environ variables
@pytest.fixture(scope="session")
def controller_scenario(
    request, get_proxmoxer, get_test_env, set_pve_cloud_auth, get_k8s_api_v1
):
    scenario_name = "controller"

    # age secret env var
    os.environ["CLOUD_AGE_SSH_KEY_FILE"] = f"{os.getcwd()}/tests/id_ed25519"

    ctlr_vers, tdd_ip = get_tdd_version("pve-cloud-controller")

    if ctlr_vers:
        # set controller base image
        os.environ["TF_VAR_cloud_controller_image"] = (
            f"{tdd_ip}:5000/pve-cloud-controller"
        )
        os.environ["TF_VAR_cloud_controller_version"] = ctlr_vers

    if not request.config.getoption("--skip-apply"):
        apply(
            "pxc-controller", scenario_name, get_k8s_api_v1, True, True
        )  # always upgrade to get tdd build provider and inject custom e2e rc

    # init aws moto mock server
    init_moto(get_proxmoxer, get_test_env)

    yield

    if not request.config.getoption("--skip-cleanup"):
        destroy(scenario_name)


@pytest.fixture(scope="session")
def deployments_scenario(request, controller_scenario, get_k8s_api_v1):
    scenario_name = "deployments"

    # generate random hostname for helm nginx test deployment
    # todo: refactor into terraform output -json and generate the random variable via tf so it doesnt change on each test run
    random_nginx_test_name = f"nginx-test-{''.join(random.choices(string.ascii_letters + string.digits, k=6)).lower()}"
    os.environ["TF_VAR_nginx_rnd_hostname"] = random_nginx_test_name

    if not request.config.getoption("--skip-apply"):
        apply("pxc-controller", scenario_name, get_k8s_api_v1, True, True)
        time.sleep(10)  # ingress dns time

    yield {"random_nginx_test_name": random_nginx_test_name}

    if not request.config.getoption("--skip-cleanup"):
        destroy(scenario_name)



@pytest.fixture(scope="session")
def harbor_scenario(request, controller_scenario, get_k8s_api_v1):
    scenario_name = "harbor"

    if not request.config.getoption("--skip-apply"):
        apply("pxc-controller", scenario_name, get_k8s_api_v1, True, True)
        # we also need to reapply the controller scenario as the controller module gets
        # secrets by discovery that are set during the harbor scenario
        # todo: this could be made faster by first checking if the secrets exist and only 
        # applying when they were first created
        apply("pxc-controller", "controller", get_k8s_api_v1, True, True)

    yield

    if not request.config.getoption("--skip-cleanup"):
        destroy(scenario_name)
