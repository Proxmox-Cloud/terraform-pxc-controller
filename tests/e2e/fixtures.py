import logging
import os
import random
import string
import time

import boto3
import dns.resolver
import pytest
from pve_cloud_test.cloud_fixtures import (cloud_fixture, get_proxmoxer,
                                           get_tdd_version, get_test_env)
from pve_cloud_test.k8s_fixtures import (construct_k0s_ext_hosts_inv,
                                         get_k8s_api_v1, get_k8s_api_v1_batch,
                                         get_k8s_secondary_api_v1,
                                         get_k8s_secondary_api_v1_batch,
                                         get_kubespray_inv,
                                         get_secondary_kubespray_inv)
from pve_cloud_test.terraform import apply, destroy, get_mc_gw_http_mock

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
    resolver.nameservers = [get_test_env["cloud_inventory"]["bind_master_ip"]]

    ddns_answer = resolver.resolve(
        f"{worker['name']}.{get_test_env['cloud_inventory']['pve_cloud_domain']}"
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
        if zone["Name"] == get_test_env["kubernetes"]["deployments_domain"] + ".":
            test_deployment_zone_exists = True
            break

    if not test_deployment_zone_exists:
        create_resp = client.create_hosted_zone(
            Name=get_test_env["kubernetes"]["deployments_domain"] + ".",
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
    resolver.nameservers = [get_test_env["cloud_inventory"]["bind_master_ip"]]

    ddns_answer = resolver.resolve(
        f"{worker['name']}.{get_test_env['cloud_inventory']['pve_cloud_domain']}"
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


# when booting up the testing system cron jobs sometimes fail
# due to unmet startup conditions, that are harmless
# we clean them up once before running tests
def cleanup_failed_startup_cronjobs(k8s_api_v1_batch):
    batch_api = k8s_api_v1_batch
    namespaces = ["pve-cloud-controller", "pxc-controller-ext"]

    for namespace in namespaces:
        jobs = batch_api.list_namespaced_job(namespace)
        logger.info(f"Number of jobs in {namespace} - {len(jobs.items)}")
        for job in jobs.items:
            if job.status.failed is not None and job.status.failed > 0:
                logger.info(
                    f"Deleting failed job {job.metadata.name} in namespace {namespace}"
                )
                batch_api.delete_namespaced_job(
                    name=job.metadata.name,
                    namespace=namespace,
                    propagation_policy="Foreground",
                )


@cloud_fixture("controller")
def controller_scenario(
    request,
    get_proxmoxer,
    get_test_env,
    get_kubespray_inv,
    get_k8s_api_v1,
    get_k8s_api_v1_batch,
):
    cleanup_failed_startup_cronjobs(get_k8s_api_v1_batch)

    scenario_name = "controller"

    # additional environmental variables for this tf scenario
    extra_apply_env = {}
    extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_kubespray_inv

    extra_apply_env["CLOUD_AGE_SSH_KEY_FILE"] = f"{os.getcwd()}/tests/id_ed25519"

    ctlr_vers, tdd_ip = get_tdd_version("pve-cloud-controller")

    if ctlr_vers:
        # set controller base image
        extra_apply_env["TF_VAR_cloud_controller_image"] = (
            f"{tdd_ip}:5000/pve-cloud-controller"
        )
        extra_apply_env["TF_VAR_cloud_controller_version"] = ctlr_vers

    apply(
        "pxc-controller",
        scenario_name,
        get_k8s_api_v1,
        get_test_env,
        extra_apply_env,
    )

    # init aws moto mock server
    init_moto(get_proxmoxer, get_test_env)

    yield

    destroy(
        "pxc-controller",
        scenario_name,
        get_test_env,
        extra_apply_env,
    )


@pytest.fixture(scope="session")
def set_tf_nginx_rndm_hostname():
    random_nginx_test_name = os.getenv("TF_VAR_nginx_rnd_hostname")
    if not random_nginx_test_name:
        # generate random hostname for helm nginx test deployment
        # todo: refactor into terraform output -json and generate the random variable via tf so it doesnt change on each test run
        random_nginx_test_name = f"nginx-test-{''.join(random.choices(string.ascii_letters + string.digits, k=6)).lower()}"
        os.environ["TF_VAR_nginx_rnd_hostname"] = random_nginx_test_name

    return random_nginx_test_name


@cloud_fixture("deployments")
def deployments_scenario(
    request,
    controller_scenario,
    get_test_env,
    get_kubespray_inv,
    get_k8s_api_v1,
    set_tf_nginx_rndm_hostname,
):
    scenario_name = "deployments"

    extra_apply_env = {}
    extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_kubespray_inv
    extra_apply_env["TF_VAR_nginx_rnd_hostname"] = set_tf_nginx_rndm_hostname

    # multi cloud gateway peer sim
    with get_mc_gw_http_mock():
        # main apply
        apply(
            "pxc-controller",
            scenario_name,
            get_k8s_api_v1,
            get_test_env,
            extra_apply_env,
        )

    time.sleep(10)  # ingress dns time

    yield {"random_nginx_test_name": set_tf_nginx_rndm_hostname}

    with get_mc_gw_http_mock():
        destroy("pxc-controller", scenario_name, get_test_env, extra_apply_env)


@cloud_fixture("harbor")
def harbor_scenario(
    request, controller_scenario, get_test_env, get_kubespray_inv, get_k8s_api_v1
):
    scenario_name = "harbor"

    extra_apply_env = {}
    extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_kubespray_inv
    extra_apply_env["CLOUD_AGE_SSH_KEY_FILE"] = f"{os.getcwd()}/tests/id_ed25519"

    ctlr_vers, tdd_ip = get_tdd_version("pve-cloud-controller")

    if ctlr_vers:
        # set controller base image
        extra_apply_env["TF_VAR_cloud_controller_image"] = (
            f"{tdd_ip}:5000/pve-cloud-controller"
        )
        extra_apply_env["TF_VAR_cloud_controller_version"] = ctlr_vers

    apply(
        "pxc-controller", scenario_name, get_k8s_api_v1, get_test_env, extra_apply_env
    )
    # we also need to reapply the controller scenario as the controller module gets
    # secrets by discovery that are set during the harbor scenario
    # todo: only do once with redis key check
    apply(
        "pxc-controller",
        "controller",
        get_k8s_api_v1,
        get_test_env,
        extra_apply_env,
    )

    yield

    destroy("pxc-controller", scenario_name, get_test_env, extra_apply_env)


@cloud_fixture("secondary")
def secondary_scenario(
    request,
    deployments_scenario,
    get_test_env,
    get_k8s_api_v1,
    get_kubespray_inv,
    get_k8s_secondary_api_v1,
    get_k8s_secondary_api_v1_batch,
    get_secondary_kubespray_inv,
    set_tf_nginx_rndm_hostname,
):
    cleanup_failed_startup_cronjobs(get_k8s_secondary_api_v1_batch)

    scenario_name = "secondary"

    # additional environmental variables for this tf scenario
    extra_apply_env = {}
    extra_apply_env["TF_VAR_nginx_rnd_hostname"] = set_tf_nginx_rndm_hostname

    ctlr_vers, tdd_ip = get_tdd_version("pve-cloud-controller")

    if ctlr_vers:
        # set controller base image
        extra_apply_env["TF_VAR_cloud_controller_image"] = (
            f"{tdd_ip}:5000/pve-cloud-controller"
        )
        extra_apply_env["TF_VAR_cloud_controller_version"] = ctlr_vers

    with get_mc_gw_http_mock():
        # main apply
        # os.environ["TF_VAR_e2e_secondary_kubespray_inv"] = temp_kubespray_inv.name
        extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_secondary_kubespray_inv
        apply(
            "pxc-controller",
            scenario_name,
            get_k8s_secondary_api_v1,
            get_test_env,
            extra_apply_env,
        )

        # after having registered our client we also need to run the deployments scenario again for the master monitoring to pick up on this
        # todo: this could be made faster by first checking if the secrets exist and only
        # applying when they were first created
        extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_kubespray_inv
        apply(
            "pxc-controller",
            "deployments",
            get_k8s_api_v1,
            get_test_env,
            extra_apply_env,
        )

    yield

    with get_mc_gw_http_mock():
        extra_apply_env["TF_VAR_e2e_kubespray_inv"] = get_secondary_kubespray_inv
        destroy(
            "pxc-controller",
            scenario_name,
            get_test_env,
            extra_apply_env,
        )


@cloud_fixture("k0s", "k0s-edge")
def k0s_edge_scenario(
    request,
    get_proxmoxer,
    get_test_env,
    # we still request the default k8s to satisfy apply methods
    # but k0s strictly doesnt need it
    get_kubespray_inv,
    get_k8s_api_v1,
):
    scenario_name = "k0s-edge"

    # additional environmental variables for this tf scenario
    extra_apply_env = {}

    # write testing kubespray inv and set the path (for provider init)
    k0s_inv, _ = construct_k0s_ext_hosts_inv(get_test_env)
    extra_apply_env["TF_VAR_e2e_k0s_ext_hosts_inv"] = k0s_inv

    ctlr_vers, tdd_ip = get_tdd_version("pve-cloud-controller")

    if ctlr_vers:
        # set controller base image
        extra_apply_env["TF_VAR_cloud_controller_image"] = (
            f"{tdd_ip}:5000/pve-cloud-controller"
        )
        extra_apply_env["TF_VAR_cloud_controller_version"] = ctlr_vers

    apply(
        "pxc-controller",
        scenario_name,
        get_k8s_api_v1,
        get_test_env,
        extra_apply_env,
    )

    yield

    destroy(
        "pxc-controller",
        scenario_name,
        get_test_env,
        extra_apply_env,
    )
