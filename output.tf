output "hostname" {
  description = "Hostname of the application."
  value = local.hostname
}

output "load_balancer_hostname" {
  description = "The elastic load balancer allocated for this service"
  value = kubernetes_service.load_balancer.status[0].load_balancer[0].ingress[0].hostname
}
