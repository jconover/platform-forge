variable "cluster_name" {
  description = "EKS cluster name. Used as a label prefix for Tailscale resources."
  type        = string
}

variable "environment" {
  description = "Environment label for resource tags and Tailscale hostname suffix."
  type        = string
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for the DaemonSet. Use a reusable, ephemeral key. Marked sensitive."
  type        = string
  sensitive   = true
}

variable "tailscale_namespace" {
  description = "Kubernetes namespace where Tailscale DaemonSet will run."
  type        = string
  default     = "tailscale"
}

variable "tailscale_image" {
  description = "Tailscale container image. Pin to a specific tag for production stability."
  type        = string
  default     = "tailscale/tailscale:latest"
}

variable "eks_pod_cidr" {
  description = "CIDR range used by EKS pods. Advertised to the Tailscale mesh so on-prem hosts can reach pods directly. Typically matches VPC private subnet CIDRs."
  type        = string
  default     = "10.0.128.0/17"
}

variable "accept_routes" {
  description = "Whether EKS nodes should accept subnet routes advertised by other Tailscale nodes (e.g., on-prem cluster). Enables hybrid cloud connectivity."
  type        = bool
  default     = true
}

variable "tailscale_hostname_prefix" {
  description = "Hostname prefix for EKS nodes in the Tailscale network. Node hostname will be <prefix>-<node-name>."
  type        = string
  default     = "eks"
}

variable "tags" {
  description = "Additional Kubernetes labels to apply to DaemonSet pods."
  type        = map(string)
  default     = {}
}
