output "secret" {
  value = kubernetes_secret.pull_secret
  sensitive = true
}
