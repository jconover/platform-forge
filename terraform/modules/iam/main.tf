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
# EKS Cluster Role
# The control plane assumes this role to manage AWS resources on your behalf.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster" {
  name_prefix = "${var.cluster_name}-cluster-"
  description = "EKS cluster control plane role for ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# ---------------------------------------------------------------------------
# EKS Node Role
# EC2 instances (worker nodes) assume this role to register with the cluster
# and pull container images from ECR.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eks_node" {
  name_prefix = "${var.cluster_name}-node-"
  description = "EKS worker node role for ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-node-role"
  })
}

# Required for nodes to join the cluster
resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# Required for the VPC CNI plugin to manage pod networking
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Required to pull container images from ECR
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Required for SSM Session Manager (no SSH bastion needed)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Required for EBS CSI driver (persistent volumes)
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Instance profile wraps the node role so EC2 instances can assume it
resource "aws_iam_instance_profile" "eks_node" {
  name_prefix = "${var.cluster_name}-node-"
  role        = aws_iam_role.eks_node.name

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Karpenter Controller Role (IRSA)
# Karpenter runs in the cluster and needs to launch/terminate EC2 instances.
# Uses IRSA so the Karpenter pod gets AWS credentials without node-level access.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "karpenter_controller" {
  name_prefix = "${var.cluster_name}-karpenter-"
  description = "Karpenter controller IRSA role for ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:karpenter:karpenter"
        }
      }
    }]
  })

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-karpenter-role"
  })
}

# Karpenter controller policy: EC2 instance management, SQS for interruption handling
resource "aws_iam_role_policy" "karpenter_controller" {
  name = "karpenter-controller"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Karpenter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ec2:DescribeImages",
          "ec2:RunInstances",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "iam:PassRole",
          "eks:DescribeCluster",
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:TagRole"
        ]
        Resource = "*"
      },
      {
        Sid      = "ConditionalEC2Termination"
        Effect   = "Allow"
        Action   = "ec2:TerminateInstances"
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        # Allow Karpenter to manage SQS queue for spot interruption notifications
        Sid    = "InterruptionQueue"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        # Allow Karpenter to pass the node role to EC2 instances it launches
        Sid      = "PassNodeIAMRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.cluster_name}-node-*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Instance profile for Karpenter-launched nodes
# Karpenter creates nodes and attaches this profile so nodes can join EKS.
# ---------------------------------------------------------------------------
resource "aws_iam_instance_profile" "karpenter_node" {
  name_prefix = "${var.cluster_name}-karpenter-node-"
  role        = aws_iam_role.eks_node.name

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-karpenter-node-profile"
  })
}

# ---------------------------------------------------------------------------
# Karpenter SQS Queue for EC2 Spot Interruption Handling
# Karpenter subscribes to this queue to get advance notice of spot terminations
# and gracefully drain nodes before termination (2-minute warning).
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "karpenter_interruption" {
  name_prefix               = "${var.cluster_name}-karpenter-"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-karpenter-interruption"
  })
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = ["events.amazonaws.com", "sqs.amazonaws.com"]
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridge rules to send interruption events to SQS
resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = {
    spot_interruption = {
      description = "Spot instance interruption warning"
      pattern = jsonencode({
        source      = ["aws.ec2"]
        detail-type = ["EC2 Spot Instance Interruption Warning"]
      })
    }
    rebalance = {
      description = "EC2 instance rebalance recommendation"
      pattern = jsonencode({
        source      = ["aws.ec2"]
        detail-type = ["EC2 Instance Rebalance Recommendation"]
      })
    }
    instance_state = {
      description = "EC2 instance state change"
      pattern = jsonencode({
        source      = ["aws.ec2"]
        detail-type = ["EC2 Instance State-change Notification"]
      })
    }
  }

  name        = "${var.cluster_name}-karpenter-${each.key}"
  description = each.value.description

  event_pattern = each.value.pattern

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each = aws_cloudwatch_event_rule.karpenter_interruption

  rule      = each.value.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}
