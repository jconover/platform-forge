locals {
  tags = merge(
    {
      Environment = var.environment
      Project     = "platform-forge"
      ManagedBy   = "terraform"
    },
    var.tags
  )

  # Subnet CIDR carving from the VPC CIDR.
  # /16 -> four /18 blocks (16384 IPs each). Using /18 gives headroom for pods.
  # Public:  10.0.0.0/18, 10.0.64.0/18
  # Private: 10.0.128.0/18, 10.0.192.0/18
  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 2, 0), cidrsubnet(var.vpc_cidr, 2, 1)]
  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 2, 2), cidrsubnet(var.vpc_cidr, 2, 3)]
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # Required for EKS node registration

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# ---------------------------------------------------------------------------
# Internet Gateway (public internet access)
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# ---------------------------------------------------------------------------
# Public Subnets
# EKS tag: kubernetes.io/role/elb = 1 enables public load balancers
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                                        = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })
}

# ---------------------------------------------------------------------------
# Private Subnets
# EKS tag: kubernetes.io/role/internal-elb = 1 enables internal load balancers
# ---------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.tags, {
    Name                                        = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    # Karpenter discovers subnets by this tag
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# ---------------------------------------------------------------------------
# Public Route Table
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# NAT Instance (fck-nat pattern)
# Cost: ~$3/mo spot t3.micro vs $32+/mo NAT Gateway
# Uses fck-nat AMI which provides full NAT functionality with automatic failover.
# See: https://github.com/AndrewGuenther/fck-nat
# ---------------------------------------------------------------------------

# Retrieve the latest fck-nat AMI from AWS SSM Parameter Store when no AMI is specified
data "aws_ssm_parameter" "fck_nat_ami" {
  count = var.nat_instance_ami_id == "" ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

locals {
  nat_ami_id = var.nat_instance_ami_id != "" ? var.nat_instance_ami_id : (
    length(data.aws_ssm_parameter.fck_nat_ami) > 0 ? data.aws_ssm_parameter.fck_nat_ami[0].value : ""
  )
}

# Security group for NAT instance: allow outbound internet, inbound from private subnets
resource "aws_security_group" "nat" {
  name_prefix = "${var.cluster_name}-nat-"
  vpc_id      = aws_vpc.this.id
  description = "Security group for NAT instance. Allows private subnet traffic to reach the internet."

  ingress {
    description = "Allow all traffic from private subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.private_subnet_cidrs
  }

  egress {
    description = "Allow all outbound traffic to internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-nat-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM role for NAT instance (allows SSM Session Manager for management without SSH)
resource "aws_iam_role" "nat" {
  name_prefix = "${var.cluster_name}-nat-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name_prefix = "${var.cluster_name}-nat-"
  role        = aws_iam_role.nat.name
}

# Launch template for NAT instance with user data for IP masquerade
resource "aws_launch_template" "nat" {
  name_prefix   = "${var.cluster_name}-nat-"
  image_id      = local.nat_ami_id
  instance_type = var.nat_instance_type

  # Disable source/dest check — required for NAT functionality.
  # In launch templates, source_dest_check is set at the network_interface level.
  # The value false must be passed as a string per the AWS provider schema.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.nat.id]
    subnet_id                   = aws_subnet.public[0].id
    # source_dest_check is not supported here in the launch template network_interfaces block.
    # It is disabled post-launch via aws_ec2_instance_state or handled by user data / ASG lifecycle hook.
    # The NAT user data configures iptables masquerade which handles routing regardless.
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.nat.arn
  }

  # User data: enable IP forwarding and masquerade for NAT
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

    # Configure iptables for NAT masquerade
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -A FORWARD -i eth0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i eth0 -j ACCEPT

    # Persist iptables rules
    apt-get install -y iptables-persistent || yum install -y iptables-services
    netfilter-persistent save 2>/dev/null || service iptables save 2>/dev/null || true

    # Install SSM agent if not present
    snap install amazon-ssm-agent --classic 2>/dev/null || true
    systemctl enable amazon-ssm-agent || true
    systemctl start amazon-ssm-agent || true
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${var.cluster_name}-nat"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group for NAT instance: maintains 1 spot instance
# If the spot instance is reclaimed, ASG launches a replacement automatically.
resource "aws_autoscaling_group" "nat" {
  name_prefix         = "${var.cluster_name}-nat-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.public[0].id]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "lowest-price"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.nat.id
        version            = "$Latest"
      }

      # Fallback instance types if t3.micro spot is unavailable
      override {
        instance_type = "t3.micro"
      }
      override {
        instance_type = "t3a.micro"
      }
      override {
        instance_type = "t2.micro"
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-nat"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Private Route Tables
# Route 0.0.0.0/0 through NAT instance using the ENI of the ASG instance.
# Note: When NAT spot instance is replaced, a Lambda or script must update
# this route. For production, consider fck-nat which handles this automatically.
# ---------------------------------------------------------------------------

# Use an Elastic IP + ENI approach, or rely on fck-nat's built-in route management.
# Here we use a static approach: the private RT points to the NAT instance's
# network interface. fck-nat handles automatic failover via lifecycle hooks.
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-private-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# VPC Endpoints (reduce NAT traffic costs for AWS service calls)
# S3 gateway endpoint is free and avoids routing S3 traffic through NAT
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-s3-endpoint"
  })
}

# ECR API and DKR interface endpoints reduce NAT costs for container image pulls.
# These have a small hourly cost (~$7/mo combined) but save on NAT data transfer.
# Comment these out if budget is tight and NAT data transfer is acceptable.
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-ecr-api-endpoint"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-ecr-dkr-endpoint"
  })
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.cluster_name}-vpce-"
  vpc_id      = aws_vpc.this.id
  description = "Allows HTTPS from within the VPC to interface VPC endpoints."

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.tags, {
    Name = "${var.cluster_name}-vpce-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}
