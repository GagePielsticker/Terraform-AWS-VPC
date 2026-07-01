output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway attached to the VPC."
  value       = aws_internet_gateway.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per AZ."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_app_subnet_ids" {
  description = "IDs of the private application-tier subnets (route to NAT), one per AZ."
  value       = [for s in aws_subnet.private_app : s.id]
}

output "private_data_subnet_ids" {
  description = "IDs of the private data-tier subnets (no internet route), one per AZ."
  value       = [for s in aws_subnet.private_data : s.id]
}

output "public_route_table_id" {
  description = "ID of the shared public-tier route table."
  value       = aws_route_table.public.id
}

output "private_app_route_table_ids" {
  description = "IDs of the private-app route tables, one per AZ."
  value       = [for rt in aws_route_table.private_app : rt.id]
}

output "private_data_route_table_id" {
  description = "ID of the shared private-data route table."
  value       = aws_route_table.private_data.id
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways, one per AZ."
  value       = [for ng in aws_nat_gateway.main : ng.id]
}

output "nat_gateway_public_ips" {
  description = "Public Elastic IP addresses of the NAT gateways, one per AZ. Use these for allow-listing outbound traffic at partner firewalls."
  value       = [for eip in aws_eip.nat : eip.public_ip]
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_endpoint_id" {
  description = "ID of the DynamoDB gateway VPC endpoint."
  value       = aws_vpc_endpoint.dynamodb.id
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group receiving VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
