variable "cluster_name" {
  description = "EKS cluster name. Used as a prefix for IAM role names and in trust policies."
  type        = string
}

variable "environment" {
  description = "Environment label for resource tags."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider. Required for IRSA trust policies."
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider without https:// prefix. Used in IAM condition keys."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID. Used in ARN construction for Karpenter policies."
  type        = string
}

variable "aws_region" {
  description = "AWS region. Used in ARN construction for Karpenter policies."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Additional tags to apply to all IAM resources."
  type        = map(string)
  default     = {}
}
