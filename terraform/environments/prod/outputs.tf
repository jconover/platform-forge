output "cluster_endpoint" {
  description = "HTTPS endpoint for the EKS API server. Used to configure kubectl and provider blocks."
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate authority data for the EKS cluster."
  value       = module.eks.cluster_certificate_authority
  sensitive   = true
}

output "vpc_id" {
  description = "ID of the VPC hosting the EKS cluster."
  value       = module.vpc.vpc_id
}

output "eks_node_role_arn" {
  description = "ARN of the IAM role attached to EKS worker nodes. Used by Karpenter and other node-level integrations."
  value       = module.iam.eks_node_role_arn
}

output "karpenter_instance_profile_name" {
  description = "EC2 instance profile name used by Karpenter when launching nodes."
  value       = module.iam.karpenter_instance_profile_name
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IRSA role."
  value       = module.iam.karpenter_controller_role_arn
}

output "private_subnet_ids" {
  description = "IDs of the private subnets where EKS nodes run."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (load balancers, NAT instance)."
  value       = module.vpc.public_subnet_ids
}
