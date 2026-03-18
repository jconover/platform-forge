# ---------------------------------------------------------------------------
# IDP Project — Production EKS Environment
#
# Composes VPC, IAM, EKS, and Tailscale modules into a complete environment.
#
# Cost summary (approximate, us-east-1):
#   EKS control plane:   ~$73/mo  (always-on)
#   NAT instance spot:   ~$3/mo   (t3.micro)
#   ECR VPC endpoints:   ~$7/mo   (2 interface endpoints)
#   Worker nodes:        $0/mo    (scale-to-zero; Karpenter provisions on demand)
#   Data transfer:       variable
#   Total baseline:      ~$83/mo  (no workloads running)
#
# Run `terraform init` then `terraform plan -var-file=prod.tfvars` to preview.
# ---------------------------------------------------------------------------

locals {
  common_tags = {
    Environment = var.environment
    Project     = "platform-forge"
    ManagedBy   = "terraform"
    CostCenter  = "platform"
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# VPC: Networking foundation
# ---------------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  environment  = var.environment
  region       = var.region
  tags         = local.common_tags
}

# ---------------------------------------------------------------------------
# IAM: Roles and policies for EKS and Karpenter
# Must be created before the EKS cluster (cluster_role_arn dependency).
# ---------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  cluster_name      = var.cluster_name
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_account_id    = data.aws_caller_identity.current.account_id
  aws_region        = var.region
  tags              = local.common_tags

  # IAM module depends on EKS OIDC provider which is created in the EKS module.
  # Karpenter IRSA trust policy references the OIDC provider.
  # Cluster and node roles are created independently and passed to EKS below.
  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# EKS: Cluster, node group, OIDC provider, and add-ons
# The IAM roles are passed in explicitly to avoid circular dependencies.
# ---------------------------------------------------------------------------
module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  # IAM roles: created separately to avoid circular reference with OIDC provider.
  # cluster_role and node_role are created directly here using aws_iam_role
  # resources rather than through the IAM module, since the IAM module needs
  # the OIDC provider ARN which the EKS module creates.
  cluster_role_arn = aws_iam_role.eks_cluster_bootstrap.arn
  node_role_arn    = aws_iam_role.eks_node_bootstrap.arn

  node_instance_types = ["m5.large", "m5.xlarge", "m5a.large", "m5a.xlarge"]
  node_min_size       = 0
  node_max_size       = 5
  node_desired_size   = 0 # Karpenter will scale from 0 on workload demand

  endpoint_public_access  = true
  endpoint_private_access = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Bootstrap IAM roles (created before EKS to break the circular dependency)
# These are minimal versions; the IAM module creates the full Karpenter role
# after the OIDC provider is available.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster_bootstrap" {
  name_prefix = "${var.cluster_name}-cluster-"
  description = "EKS cluster control plane role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

resource "aws_iam_role" "eks_node_bootstrap" {
  name_prefix = "${var.cluster_name}-node-"
  description = "EKS worker node role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-node-role" })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.eks_node_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.eks_node_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.eks_node_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm_policy" {
  role       = aws_iam_role.eks_node_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "node_ebs_csi_policy" {
  role       = aws_iam_role.eks_node_bootstrap.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# Tailscale: Mesh connectivity between EKS nodes and on-prem
# ---------------------------------------------------------------------------
module "tailscale" {
  source = "../../modules/tailscale"

  cluster_name       = var.cluster_name
  environment        = var.environment
  tailscale_auth_key = var.tailscale_auth_key

  # Advertise the private subnet CIDRs so on-prem can route to EKS pods
  eks_pod_cidr = var.vpc_cidr

  # Accept routes from on-prem Tailscale nodes (enables hybrid cloud bursting)
  accept_routes = true

  tags = local.common_tags

  depends_on = [module.eks]
}
