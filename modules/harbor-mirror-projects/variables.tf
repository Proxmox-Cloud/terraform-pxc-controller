variable "harbor_host" {
  type = string
}

variable "skip_pxc_secret_creation_e2e" {
  type = bool
  default = false
  description = "Can be toggeled on to rely on externally injected discovery of remote artifactory for faster e2e testing."
}