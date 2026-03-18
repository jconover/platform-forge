locals {
  tags = merge(
    {
      Environment = var.environment
      Project     = "platform-forge"
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

# ---------------------------------------------------------------------------
# EKS Cluster
# Cost: ~$73/mo for the control plane regardless of node count.
# Kubernetes 1.32 is the target version.
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    security_group_ids      = [aws_security_group.cluster_additional.id]
  }

  # Enable control plane logging (CloudWatch Logs — small cost, high value for debugging)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Ensure IAM role and its policies are in place before creating the cluster
  depends_on = [var.cluster_role_arn]

  tags = merge(local.tags, {
    Name = var.cluster_name
  })
}

# ---------------------------------------------------------------------------
# Additional cluster security group rules
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster_additional" {
  name_prefix = "${var.cluster_name}-cluster-add-"
  vpc_id      = var.vpc_id
  description = "Additional rules for the EKS cluster. Allows Tailscale UDP traffic."

  # Tailscale uses UDP 41641 for encrypted WireGuard tunnels between nodes
  ingress {
    description = "Tailscale WireGuard - mesh connectivity between EKS nodes and on-prem"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-cluster-additional-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# Required for Karpenter controller, aws-load-balancer-controller, etc.
# ---------------------------------------------------------------------------
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

# ---------------------------------------------------------------------------
# EKS Managed Node Group (spot instances, scale-to-zero)
# Cost: $0 when desired=0. Nodes provisioned on-demand by Karpenter.
# Initial node group exists as a fallback and for system pods (coredns, etc.)
# ---------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  # Spot instances: significant cost savings vs on-demand (60-90% cheaper)
  capacity_type  = "SPOT"
  instance_types = var.node_instance_types

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  # Allow rolling updates without downtime
  update_config {
    max_unavailable = 1
  }

  # Labels for system node selection
  labels = {
    role        = "system"
    environment = var.environment
  }

  # Karpenter will discover this node group
  tags = merge(local.tags, {
    Name                     = "${var.cluster_name}-system-node"
    "karpenter.sh/discovery" = var.cluster_name
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_eks_cluster.this]
}

# ---------------------------------------------------------------------------
# EKS Add-ons
# These are managed by AWS and kept updated automatically.
# ---------------------------------------------------------------------------

# vpc-cni: AWS VPC CNI plugin for pod networking
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.this]
}

# coredns: DNS resolution for pods
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.this]
}

# kube-proxy: network rules on each node
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.this]
}

# aws-ebs-csi-driver: persistent volume support via EBS
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.this]
}
