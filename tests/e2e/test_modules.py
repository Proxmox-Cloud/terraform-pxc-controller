
from scenarios import *
import ssl
import socket
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import NameOID
import time
from kubernetes import client
import dns.query
import dns.tsigkeyring
import dns.zone
import logging
import requests
import pprint
import random
import string
from kubernetes.stream import stream
from kubernetes.client import V1ObjectMeta, V1Job, V1JobSpec
import json
import requests
from kubernetes.client.rest import ApiException
import pytest


logger = logging.getLogger(__name__)


def test_adm_pod_creation(get_k8s_api_v1, controller_scenario):
  logger.info("test admission controller pod create")
  v1 = get_k8s_api_v1

  # test namespace and pod creation => admission controller success
  namespace = "pytest-namespace"

  try:
    # test create namespace
    v1.create_namespace(client.V1Namespace(
      metadata=client.V1ObjectMeta(name=namespace)
    ))

    # create pod in namespace
    pod_manifest = client.V1Pod(
        metadata=client.V1ObjectMeta(name="pytest-pod"),
        spec=client.V1PodSpec(
            containers=[
                client.V1Container(
                    name="busybox",
                    image="busybox",
                    command=["sh", "-c", "echo Hello from the pod && sleep 5"]
                )
            ],
            restart_policy="Never"
        )
    )
    v1.create_namespaced_pod(namespace=namespace, body=pod_manifest)

    # poll the pod status
    while True:
      pod_status = v1.read_namespaced_pod_status(name="pytest-pod", namespace=namespace)
      phase = pod_status.status.phase
      assert phase in ("Succeeded", "Running", "Pending")
      if phase in ("Succeeded", "Failed"):
        break

      time.sleep(1)

    # validate no errors in pve-cloud-controller ns
    ctlr_pods = v1.list_namespaced_pod(namespace="pve-cloud-controller").items
    assert ctlr_pods

    for pod in ctlr_pods:
      assert pod.status.phase in ["Running", "Succeeded"]
      
      for status in pod.status.container_statuses:
        assert status.restart_count == 0

  finally:
    # cleanup
    v1.delete_namespace(name=namespace)


def test_cloud_cron_execution(set_k8s_auth, controller_scenario):
  logger.info("test cron exec")

  kubeconfig = set_k8s_auth

  # auth kubernetes api
  with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_file:
    temp_file.write(kubeconfig)
    temp_file.flush()
    config.load_kube_config(config_file=temp_file.name)

  v1 = client.CoreV1Api()
  v1_batch = client.BatchV1Api()
  # trigger the backup cron and monitor
  cronjob_name = "pve-cloud-cron"
  cj = v1_batch.read_namespaced_cron_job(name=cronjob_name, namespace="pve-cloud-controller")
  tmpl = cj.spec.job_template
  job_name = f"{cronjob_name}-manual-{int(time.time())}"

  print(f"launching {job_name}")

  job = V1Job(
      metadata=V1ObjectMeta(name=job_name),
      spec=V1JobSpec(
          template=tmpl.spec.template,
          backoff_limit=tmpl.spec.backoff_limit,
      ),
  )

  job = v1_batch.create_namespaced_job(namespace="pve-cloud-controller", body=job)

  while True:
    time.sleep(5) # give pods some time to create / dont spam api

    # fetch the pod and wait for it to finish
    pods = v1.list_namespaced_pod(
      namespace="pve-cloud-controller",
      label_selector=f"job-name={job_name}"
    ).items

    assert pods

    pod = pods[0]

    phase = pod.status.phase

    assert phase != "Failed", f"pod {pod.metadata.name} failed!" # failed pods end tests immediatly

    if phase == "Succeeded":
      break # finished

    logger.info(f"pod {pod.metadata.name} in phase {phase}")



def test_delete_ingress(get_test_env, set_k8s_auth, controller_scenario, get_moto_client, set_pve_cloud_auth):
  kubeconfig = set_k8s_auth
  
  # auth kubernetes api
  with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_file:
    temp_file.write(kubeconfig)
    temp_file.flush()
    config.load_kube_config(config_file=temp_file.name)

  api = client.NetworkingV1Api()

  # test block logic
  ingress_body = client.V1Ingress(
      metadata=client.V1ObjectMeta(
        name="test-delete-ingress",
        namespace="default",
      ),
      spec=client.V1IngressSpec(
          ingress_class_name="nginx",
          rules=[
              client.V1IngressRule(
                  host=f"test-dns-delete.{get_test_env['pve_test_deployments_domain']}",
                  http=client.V1HTTPIngressRuleValue(
                      paths=[
                          client.V1HTTPIngressPath(
                              path="/",
                              path_type="Prefix",
                              backend=client.V1IngressBackend(
                                  service=client.V1IngressServiceBackend(
                                      name="nonexistent-service",  # <-- Invalid on purpose
                                      port=client.V1ServiceBackendPort(number=80)
                                  )
                              )
                          )
                      ]
                  )
              )
          ]
      )
  )

  resp = api.create_namespaced_ingress(
      namespace="default",
      body=ingress_body
  )

  api.delete_namespaced_ingress(name="test-delete-ingress", namespace="default")

  # validate its gone in bind dns and moto
  bind_internal_key = set_pve_cloud_auth["bind_internal_key"]

  # assert deleted from bind
  zone = dns.zone.from_xfr(
    dns.query.xfr(
      get_test_env["pve_test_cloud_inv"]["bind_master_ip"], 
      get_test_env["pve_test_deployments_domain"], 
      keyring=dns.tsigkeyring.from_text({"internal.": bind_internal_key}), 
      keyname="internal.",
      keyalgorithm="hmac-sha256"
    )
  )

  bind_records = [name.to_text() for name, _ in zone.nodes.items()]
  logger.info(bind_records)

  assert "test-dns-delete" not in bind_records

  # validate not in boto aws
  existing_zones = get_moto_client.list_hosted_zones()["HostedZones"]

  logger.info(existing_zones)

  assert existing_zones

  test_deployment_zone = None
  for zone in existing_zones:
    if zone["Name"] == get_test_env['pve_test_deployments_domain'] + ".":
      test_deployment_zone = zone
      break
  
  assert test_deployment_zone

  paginator = get_moto_client.get_paginator("list_resource_record_sets")
  
  all_records = []
  for page in paginator.paginate(HostedZoneId=test_deployment_zone["Id"]):
    all_records.extend(page["ResourceRecordSets"])

  logger.info(all_records)
  assert all_records

  ext_record = None
  for record in all_records:
    if "test-dns-delete" in record["Name"]:
      ext_record = record
      break
  
  assert not ext_record



def test_update_ingress(get_test_env, set_k8s_auth, controller_scenario, get_moto_client, set_pve_cloud_auth):
  kubeconfig = set_k8s_auth
  
  # auth kubernetes api
  with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_file:
    temp_file.write(kubeconfig)
    temp_file.flush()
    config.load_kube_config(config_file=temp_file.name)

  api = client.NetworkingV1Api()

  # test block logic
  ingress_body = client.V1Ingress(
      metadata=client.V1ObjectMeta(
        name="test-update-ingress",
        namespace="default",
      ),
      spec=client.V1IngressSpec(
          ingress_class_name="nginx",
          rules=[
              client.V1IngressRule(
                  host=f"test-dns-update-initial.{get_test_env['pve_test_deployments_domain']}",
                  http=client.V1HTTPIngressRuleValue(
                      paths=[
                          client.V1HTTPIngressPath(
                              path="/",
                              path_type="Prefix",
                              backend=client.V1IngressBackend(
                                  service=client.V1IngressServiceBackend(
                                      name="nonexistent-service",  # <-- Invalid on purpose
                                      port=client.V1ServiceBackendPort(number=80)
                                  )
                              )
                          )
                      ]
                  )
              )
          ]
      )
  )

  created = api.create_namespaced_ingress(
      namespace="default",
      body=ingress_body
  )

  created.spec.rules = [
      client.V1IngressRule(
          host=f"test-dns-update-updated.{get_test_env['pve_test_deployments_domain']}",
          http=created.spec.rules[0].http  # keep existing paths
      )
  ]

  updated = api.replace_namespaced_ingress(
      name="test-update-ingress",
      namespace="default",
      body=created
  )

  # validate new record was created and old deleted
  bind_internal_key = set_pve_cloud_auth["bind_internal_key"]

  # assert deleted from bind
  zone = dns.zone.from_xfr(
    dns.query.xfr(
      get_test_env["pve_test_cloud_inv"]["bind_master_ip"], 
      get_test_env["pve_test_deployments_domain"], 
      keyring=dns.tsigkeyring.from_text({"internal.": bind_internal_key}), 
      keyname="internal.",
      keyalgorithm="hmac-sha256"
    )
  )

  bind_records = [name.to_text() for name, _ in zone.nodes.items()]
  logger.info(bind_records)

  assert "test-dns-update-updated" in bind_records

  assert "test-dns-update-initial" not in bind_records

  api.delete_namespaced_ingress(name="test-update-ingress", namespace="default")



def test_ingress_connectivity(get_test_env, get_k8s_api_v1, deployments_scenario):
  logger.info("test ingress 443 connectivity via haproxy")
  v1 = get_k8s_api_v1
  random_nginx_test_name = deployments_scenario["random_nginx_test_name"]

  # validate custom nginx with self signed cert
  resolver = dns.resolver.Resolver()
  resolver.nameservers = [get_test_env["pve_test_cloud_inv"]["bind_master_ip"],get_test_env["pve_test_cloud_inv"]["bind_slave_ip"]]
  answers = resolver.resolve(f"{random_nginx_test_name}.{get_test_env['pve_test_deployments_domain']}", 'A')
  proxy_ip_resolved = answers[0].to_text()
  logger.info(proxy_ip_resolved)

  assert proxy_ip_resolved == get_test_env["pve_test_cloud_inv_cluster"]["pve_haproxy_floating_ip_internal"]
  
  context = ssl.create_default_context()
  context.check_hostname = False
  context.verify_mode = ssl.CERT_NONE 

  conn = socket.create_connection((proxy_ip_resolved, 443), timeout=5)
  ssl_sock = context.wrap_socket(conn, server_hostname=f"{random_nginx_test_name}.{get_test_env['pve_test_deployments_domain']}")
  cert = ssl_sock.getpeercert(binary_form=True)
  x509_cert = x509.load_der_x509_certificate(cert, default_backend())

  assert x509_cert.issuer.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value == "nginx-ca"

  ssl_sock.close()


def test_proxy_proto_403(get_test_env, deployments_scenario):
  logger.info("validate 403 from proxy proto")
  url = f"https://nginx-test-prxy-proto.{get_test_env['pve_test_deployments_domain']}"

  response = requests.get(url, verify=False)

  assert response.status_code == 403


def test_ingress_cluster_cert_block(get_test_env, set_k8s_auth, controller_scenario):
  kubeconfig = set_k8s_auth

  # auth kubernetes api
  with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp_file:
    temp_file.write(kubeconfig)
    temp_file.flush()
    config.load_kube_config(config_file=temp_file.name)

  api = client.NetworkingV1Api()

  # test block logic
  ingress_body = client.V1Ingress(
      metadata=client.V1ObjectMeta(
        name="test-deny-ingress",
        namespace="default",
      ),
      spec=client.V1IngressSpec(
          ingress_class_name="nginx",
          rules=[
              client.V1IngressRule(
                  host="test.google.com",
                  http=client.V1HTTPIngressRuleValue(
                      paths=[
                          client.V1HTTPIngressPath(
                              path="/",
                              path_type="Prefix",
                              backend=client.V1IngressBackend(
                                  service=client.V1IngressServiceBackend(
                                      name="nonexistent-service",  # <-- Invalid on purpose
                                      port=client.V1ServiceBackendPort(number=80)
                                  )
                              )
                          )
                      ]
                  )
              )
          ]
      )
  )

  with pytest.raises(ApiException) as exc_info:
    resp = api.create_namespaced_ingress(
        namespace="default",
        body=ingress_body
    )
  
  assert exc_info.value.status == 500
  assert "is not covered by the clusters certificate!" in exc_info.value.body

  # test allow logic

  ingress_body = client.V1Ingress(
      metadata=client.V1ObjectMeta(
        name="test-allow-ingress",
        namespace="default",
      ),
      spec=client.V1IngressSpec(
          ingress_class_name="nginx",
          rules=[
              client.V1IngressRule(
                  host=f"test.{get_test_env['pve_test_deployments_domain']}",
                  http=client.V1HTTPIngressRuleValue(
                      paths=[
                          client.V1HTTPIngressPath(
                              path="/",
                              path_type="Prefix",
                              backend=client.V1IngressBackend(
                                  service=client.V1IngressServiceBackend(
                                      name="nonexistent-service",  # <-- Invalid on purpose
                                      port=client.V1ServiceBackendPort(number=80)
                                  )
                              )
                          )
                      ]
                  )
              )
          ]
      )
  )

  resp = api.create_namespaced_ingress(
      namespace="default",
      body=ingress_body
  )

  print(resp)

  # cleanup
  api.delete_namespaced_ingress(name="test-allow-ingress", namespace="default")



def test_ingress_dns(get_test_env, set_pve_cloud_auth, deployments_scenario):
  logger.info("test ingress dns bind record creation")
  bind_internal_key = set_pve_cloud_auth["bind_internal_key"]
  random_nginx_test_name = deployments_scenario["random_nginx_test_name"]

  # test ingress dns admission controller, if records were made for test-nginx helm deployment
  zone = dns.zone.from_xfr(
    dns.query.xfr(
      get_test_env["pve_test_cloud_inv"]["bind_master_ip"], 
      get_test_env["pve_test_deployments_domain"], 
      keyring=dns.tsigkeyring.from_text({"internal.": bind_internal_key}), 
      keyname="internal.",
      keyalgorithm="hmac-sha256"
    )
  )

  assert random_nginx_test_name in [name.to_text() for name, _ in zone.nodes.items()]
  

def test_monitoring_alert_rules(get_test_env, deployments_scenario):
  logger.info("test prometheus alert manager rules firing")
 
  response = requests.get(f"http://alertmgr.{get_test_env['pve_test_deployments_domain']}/api/v2/alerts", timeout=5)
  response.raise_for_status()

  alerts = response.json()

  logger.info(pprint.pformat(alerts))

  critical_alerts = []
  warning_alerts = []
  
  for alert in alerts:
    severity = alert["labels"]["severity"]

    if severity == "critical":
      critical_alerts.append(alert["labels"]["alertname"])
    elif severity == "warning":
      warning_alerts.append(alert["labels"]["alertname"])

  if warning_alerts:
    logger.warning(f"Warning alerts firing: {', '.join(warning_alerts)}")

  assert not critical_alerts, f"Critical alerts firing: {', '.join(critical_alerts)}"




def test_external_ingress_dns(get_k8s_api_v1, get_proxmoxer, get_test_env, deployments_scenario, get_moto_client):
  logger.info("test external ingress dns route53")
  v1 = get_k8s_api_v1

  client = get_moto_client

  existing_zones = client.list_hosted_zones()["HostedZones"]

  logger.info(existing_zones)

  assert existing_zones

  test_deployment_zone = None
  for zone in existing_zones:
    if zone["Name"] == get_test_env['pve_test_deployments_domain'] + ".":
      test_deployment_zone = zone
      break
  
  assert test_deployment_zone

  paginator = client.get_paginator("list_resource_record_sets")
  
  all_records = []
  for page in paginator.paginate(HostedZoneId=test_deployment_zone["Id"]):
    all_records.extend(page["ResourceRecordSets"])

  logger.info(all_records)
  assert all_records

  # random nginx test is not covered by external domains so it shouldnt be in the records
  random_nginx_test_name = deployments_scenario["random_nginx_test_name"]

  ext_record = None
  for record in all_records:
    if random_nginx_test_name in record["Name"]:
      ext_record = record
      break
  
  assert not ext_record

  # however external-example nginx test is so it should be in the records
  ext_record = None
  for record in all_records:
    if "external-example" in record["Name"]:
      ext_record = record
      break
  
  assert ext_record

  logger.info(ext_record)
    

def test_delete_namespace_ingress_hook(get_test_env, get_k8s_api_v1, deployments_scenario, set_pve_cloud_auth):
  v1 = get_k8s_api_v1
  # first we assert the internal hostname that it was created
  bind_internal_key = set_pve_cloud_auth["bind_internal_key"]

  zone = dns.zone.from_xfr(
    dns.query.xfr(
      get_test_env["pve_test_cloud_inv"]["bind_master_ip"], 
      get_test_env["pve_test_deployments_domain"], 
      keyring=dns.tsigkeyring.from_text({"internal.": bind_internal_key}), 
      keyname="internal.",
      keyalgorithm="hmac-sha256"
    )
  )

  bind_records = [name.to_text() for name, _ in zone.nodes.items()]
  logger.info(bind_records)

  assert "nginx-ns-delete-test" in bind_records

  # then we delete the namespace and wait for it to be gone
  namespace = "nginx-ns-delete-test"
  try:
      v1.delete_namespace(name=namespace)
  except ApiException as e:
      raise
  
  start = time.time()

  while True:
    try:
      v1.read_namespace(name=namespace)

      if time.time() - start > 300: # max 300 seconds timeout
        raise TimeoutError()

      time.sleep(5)

    except ApiException as e:
      if e.status == 404:
        break
      raise
      
  # then we assert it was deleted
  zone = dns.zone.from_xfr(
    dns.query.xfr(
      get_test_env["pve_test_cloud_inv"]["bind_master_ip"], 
      get_test_env["pve_test_deployments_domain"], 
      keyring=dns.tsigkeyring.from_text({"internal.": bind_internal_key}), 
      keyname="internal.",
      keyalgorithm="hmac-sha256"
    )
  )

  bind_records = [name.to_text() for name, _ in zone.nodes.items()]
  logger.info(bind_records)

  assert "nginx-ns-delete-test" not in bind_records

