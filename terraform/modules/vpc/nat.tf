# One NAT per AZ. Costs ~2× a single-NAT design (per Well-Architected Cost)
# but survives an AZ failure of the NAT itself (per Well-Architected
# Reliability). Reliability wins the tiebreak per CLAUDE.md.

resource "aws_eip" "nat" {
  for_each = local.az_by_index
  domain   = "vpc"

  tags = {
    Name = "${var.project}-${var.environment}-nat-${each.value}"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each      = local.az_by_index
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${var.project}-${var.environment}-nat-${each.value}"
  }

  depends_on = [aws_internet_gateway.main]
}

# Default route out of each app-tier route table → the NAT in the same AZ.
# Data tier deliberately omitted — see subnets.tf.
resource "aws_route" "private_app_internet" {
  for_each               = local.az_by_index
  route_table_id         = aws_route_table.private_app[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}
