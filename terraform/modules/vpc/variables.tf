variable "cluster_name" {
  description = "EKS cluster name. Used for EKS-required subnet tags (kubernetes.io/cluster/<name>)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment" {
  description = "Environment label applied to all resource tags."
  type        = string
}

variable "region" {
  description = "AWS region. Used to select availability zones."
  type        = string
  default     = "us-east-1"
}

# Cost note: using 2 AZs instead of 3 to minimize NAT costs and data transfer.
# EKS requires at least 2 AZs for high availability of the control plane.
variable "availability_zones" {
  description = "List of 2 availability zones for subnets. EKS requires at least 2."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "nat_instance_type" {
  description = "EC2 instance type for the NAT instance. t3.micro spot costs ~$3/mo vs $32/mo for a NAT Gateway."
  type        = string
  default     = "t3.micro"
}

variable "nat_instance_ami_id" {
  description = "AMI ID for the NAT instance. Use fck-nat (https://github.com/AndrewGuenther/fck-nat) or Amazon Linux 2 with NAT configured. Leave empty to use latest fck-nat AMI via SSM."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources in this module."
  type        = map(string)
  default     = {}
}
