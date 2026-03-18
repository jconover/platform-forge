variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Used as a prefix for related resources."
  type        = string
  default     = "idp-prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Subnets are carved from this range."
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment" {
  description = "Deployment environment label (prod, staging, dev). Used in resource tags."
  type        = string
  default     = "prod"
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for the DaemonSet. Use a reusable, ephemeral key from tailscale.com/admin/settings/keys. Marked sensitive to prevent logging."
  type        = string
  sensitive   = true
}

variable "budget_alert_email" {
  description = "Email address for AWS Budget threshold breach notifications."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.34"
}
