data "aws_region" "current" {}

locals {
  # Deterministic AZ index map. Every AZ-keyed resource in this module
  # iterates over this — keeps the resource-key surface identical across
  # subnets, route tables, EIPs, NAT gateways, and alarms.
  az_by_index = { for i, az in var.azs : i => az }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}
