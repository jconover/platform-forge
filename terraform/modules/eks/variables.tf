variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane. EKS control plane costs ~$73/mo regardless of node count."
  type        = string
  default     = "1.34"
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be created."
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EKS worker nodes. Minimum 2 subnets in different AZs required."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs. Used for public API server endpoint (if enabled) and load balancers."
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster control plane."
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the IAM role for EKS worker nodes."
  type        = string
}

variable "environment" {
  description = "Environment label for resource tags."
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the initial managed node group. Spot instances are used for cost savings."
  type        = list(string)
  default     = ["m5.large", "m5.xlarge", "m5a.large", "m5a.xlarge"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group. Set to 0 for scale-to-zero (requires Karpenter or manual scaling)."
  type        = number
  default     = 0
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group."
  type        = number
  default     = 5
}

variable "node_desired_size" {
  description = "Desired number of nodes. Set to 0 to start with no running nodes (scale-to-zero). Karpenter will provision nodes on demand."
  type        = number
  default     = 0
}

variable "endpoint_public_access" {
  description = "Enable public API server endpoint. Required for kubectl from outside the VPC."
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Enable private API server endpoint (access from within VPC)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to all resources."
  type        = map(string)
  default     = {}
}
