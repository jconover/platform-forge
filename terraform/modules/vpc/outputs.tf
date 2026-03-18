output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (2 AZs). Used for load balancers and the NAT instance."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (2 AZs). EKS worker nodes run here."
  value       = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "CIDR blocks of private subnets. Used for NAT security group rules."
  value       = aws_subnet.private[*].cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "nat_security_group_id" {
  description = "Security group ID of the NAT instance."
  value       = aws_security_group.nat.id
}

output "private_route_table_ids" {
  description = "IDs of the private route tables. Used when updating NAT routes on instance replacement."
  value       = aws_route_table.private[*].id
}
