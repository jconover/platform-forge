output "eks_cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role. Pass to the EKS module as cluster_role_arn."
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_role_arn" {
  description = "ARN of the EKS node IAM role. Pass to the EKS module as node_role_arn."
  value       = aws_iam_role.eks_node.arn
}

output "eks_node_role_name" {
  description = "Name of the EKS node IAM role."
  value       = aws_iam_role.eks_node.name
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IRSA role. Used in the Karpenter Helm chart serviceAccountAnnotations."
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_instance_profile_name" {
  description = "Name of the EC2 instance profile for Karpenter-launched nodes."
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_instance_profile_arn" {
  description = "ARN of the EC2 instance profile for Karpenter-launched nodes."
  value       = aws_iam_instance_profile.karpenter_node.arn
}
