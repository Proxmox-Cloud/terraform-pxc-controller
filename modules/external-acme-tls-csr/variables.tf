variable "cert_config" {
  type = list(object({
    zone = string
    names = list(string)
    apex_zone_san = optional(bool, false)
  }))
}

locals {
  subdomain_sans = flatten([
    for entry in var.cert_config : [
      for name in entry.names : "${name}.${entry.zone}"
    ]
  ])

  apex_sans = flatten([
    for entry in var.cert_config : 
    entry.apex_zone_san ? [entry.zone] : []
  ])

  all_sans = concat(local.subdomain_sans, local.apex_sans)

  common_name = local.subdomain_sans[0]
}
