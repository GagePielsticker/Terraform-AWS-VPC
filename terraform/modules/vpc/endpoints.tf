# S3 and DynamoDB gateway VPC endpoints.
#
# Both are free (no per-hour or per-GB charge) and route traffic to the
# service over the AWS backbone instead of via NAT + public internet. That
# means:
#   - Data-tier subnets (which have no NAT route) can still reach S3/DDB.
#   - App-tier subnets skip NAT $ + NAT bandwidth for S3/DDB traffic.
# Attached to every route table so the shortest path always wins regardless
# of which tier a workload lands in.

locals {
  gateway_endpoint_route_table_ids = concat(
    [aws_route_table.public.id],
    [for rt in aws_route_table.private_app : rt.id],
    [aws_route_table.private_data.id],
  )
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_table_ids

  tags = {
    Name = "${var.project}-${var.environment}-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.gateway_endpoint_route_table_ids

  tags = {
    Name = "${var.project}-${var.environment}-dynamodb"
  }
}
