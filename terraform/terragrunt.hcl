locals {
  env_hcl     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  environment = local.env_hcl.locals.environment

  project = "REPLACE_ME_PROJECT_NAME" #REPLACE THIS
  team    = "REPLACE_ME_TEAM_NAME"    #REPLACE THIS
  region  = "us-east-1"

  # Default AZ suffixes. Every AWS region has at least a/b; c is universally
  # available in the regions this project targets. Override per env only if
  # a specific env needs to skip a bad AZ.
  az_suffixes = ["a", "b"]
  azs         = [for s in local.az_suffixes : "${local.region}${s}"]

  common_tags = {
    project     = local.project
    team        = local.team
    environment = local.environment
  }
}

terraform {
  source = "${get_parent_terragrunt_dir()}/modules/vpc"
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = "${local.environment}-infra-tf-state"
    key          = "${local.project}/terraform.tfstate"
    region       = local.region
    use_lockfile = true
    encrypt      = true
  }
}

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.10.0"
      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.42.0"
        }
      }
    }
  EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.region}"
      default_tags {
        tags = ${jsonencode(local.common_tags)}
      }
    }
  EOF
}

# Inputs common to every environment. Per-env overrides (vpc_cidr, optional
# az override, optional alarm-threshold overrides) go in each env's
# terragrunt.hcl.
inputs = {
  project     = local.project
  environment = local.environment
  azs         = local.azs
}
