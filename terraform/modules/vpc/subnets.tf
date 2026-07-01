# Six subnets from a /16 VPC: 2 AZs × 3 tiers, each subnet a /20.
# Layout is deterministic — cidrsubnet(vpc, 4, N) picks the N-th /20:
#
#   slot 0 → public[0]        (first  AZ)
#   slot 1 → public[1]        (second AZ)
#   slot 2 → private_app[0]
#   slot 3 → private_app[1]
#   slot 4 → private_data[0]
#   slot 5 → private_data[1]
#
# 6 of 16 possible /20 slots are used; the remaining 10 are reserved for
# future tiers (e.g. transit, secondary data) without renumbering.

resource "aws_subnet" "public" {
  for_each = local.az_by_index

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.key)
  availability_zone       = each.value
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${each.value}"
    tier = "public"
  }
}

resource "aws_subnet" "private_app" {
  for_each = local.az_by_index

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.key + 2)
  availability_zone = each.value

  tags = {
    Name = "${var.project}-${var.environment}-private-app-${each.value}"
    tier = "private-app"
  }
}

resource "aws_subnet" "private_data" {
  for_each = local.az_by_index

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.key + 4)
  availability_zone = each.value

  tags = {
    Name = "${var.project}-${var.environment}-private-data-${each.value}"
    tier = "private-data"
  }
}

# Public tier: one shared route table (all public subnets route to the same
# IGW; per-AZ tables would be pure duplication).
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private-app tier: one route table per AZ so each app subnet egresses via
# its own AZ's NAT (see nat.tf) — an AZ failure only takes down that AZ's
# outbound path, not the whole VPC's.
resource "aws_route_table" "private_app" {
  for_each = local.az_by_index

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-private-app-${each.value}"
  }
}

resource "aws_route_table_association" "private_app" {
  for_each       = aws_subnet.private_app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_app[each.key].id
}

# Private-data tier: one shared route table. Only routes present:
#   1. Implicit `local` route for the VPC CIDR (AWS-managed, not declared).
#   2. Gateway VPC endpoint entries added by endpoints.tf (S3, DynamoDB).
# NO 0.0.0.0/0 route — the data tier has no path to the internet. Workloads
# here are reachable only from the app tier via security groups.
resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-private-data"
  }
}

resource "aws_route_table_association" "private_data" {
  for_each       = aws_subnet.private_data
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_data.id
}
