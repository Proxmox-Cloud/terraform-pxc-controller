# this is the terraform version of pxc.cloud roles apply_acme_certs role
# used to provide tls for external non pxc k8s clusters
resource "tls_private_key" "cert_key" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "csr" {
  private_key_pem = tls_private_key.cert_key.private_key_pem

  subject {
    common_name = local.common_name
  }

  dns_names = local.all_sans
}

resource "pxc_external_acme_tls" "external_tls" {
  config = {
    cn = local.common_name
    san =  local.all_sans
    workflow = "acme"
  }
  ec_csr = {
    csr = tls_cert_request.csr.cert_request_pem
    privkey = tls_private_key.cert_key.private_key_pem
  }
}

output "config" {
  value = {
    cn = local.common_name
    san =  local.all_sans
    workflow = "acme"
  }
}

output "ec_csr" {
  value       = {
    csr = nonsensitive(tls_cert_request.csr.cert_request_pem)
    privkey = nonsensitive(tls_private_key.cert_key.private_key_pem)
  }
}