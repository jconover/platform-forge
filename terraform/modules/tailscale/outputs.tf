output "namespace" {
  description = "Kubernetes namespace where Tailscale is deployed."
  value       = kubernetes_namespace_v1.tailscale.metadata[0].name
}

output "daemonset_name" {
  description = "Name of the Tailscale DaemonSet."
  value       = kubernetes_daemon_set_v1.tailscale.metadata[0].name
}

output "service_account_name" {
  description = "Name of the Tailscale ServiceAccount."
  value       = kubernetes_service_account_v1.tailscale.metadata[0].name
}
