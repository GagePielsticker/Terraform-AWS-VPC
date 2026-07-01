variable "project" {
  description = "Project slug used to name every resource. Wired from the root terragrunt.hcl."
  type        = string
}

variable "environment" {
  description = "Environment name (dev/qa/prod). Wired from the root terragrunt.hcl."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC. Must be a /16 — the module derives six deterministic /20 subnets from it. No default, set per env."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid IPv4 CIDR ending in /16 (e.g. 10.10.0.0/16)."
  }
}

variable "azs" {
  description = "Exactly two AZ names in the target region. First AZ receives subnets in slots 0/2/4, second in slots 1/3/5."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "azs must contain exactly two AZ names — this module is fixed at 2-AZ by design."
  }

  validation {
    condition     = length(distinct(var.azs)) == 2
    error_message = "azs must contain two distinct AZs."
  }
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention (days) for VPC Flow Logs. Must be a value CloudWatch accepts."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.flow_log_retention_days
    )
    error_message = "flow_log_retention_days must be one of the CloudWatch-supported retention values (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "nat_alarm_actions" {
  description = "Optional list of SNS topic ARNs to notify on NAT alarm state changes (both ALARM and OK). Leave empty for observe-only alarms — they still appear in the CloudWatch console."
  type        = list(string)
  default     = []
}

variable "nat_port_allocation_error_threshold" {
  description = "ErrorPortAllocation count above which the port-exhaustion alarm fires (1-minute window). Any non-zero value means outbound connections are being refused, so 0 is the correct default."
  type        = number
  default     = 0

  validation {
    condition     = var.nat_port_allocation_error_threshold >= 0
    error_message = "nat_port_allocation_error_threshold must be zero or positive."
  }
}

variable "nat_packet_drop_threshold" {
  description = "PacketsDropCount above which the drop alarm fires (evaluated over 5 one-minute windows). 0 = alarm on any sustained drop."
  type        = number
  default     = 0

  validation {
    condition     = var.nat_packet_drop_threshold >= 0
    error_message = "nat_packet_drop_threshold must be zero or positive."
  }
}

variable "nat_bytes_out_alarm_threshold_gb" {
  description = "BytesOutToDestination alarm threshold in GiB per 5-minute window (evaluated over 3 consecutive windows = 15 minutes sustained). Sized to catch runaway workloads and cost surprises."
  type        = number
  default     = 5

  validation {
    condition     = var.nat_bytes_out_alarm_threshold_gb > 0
    error_message = "nat_bytes_out_alarm_threshold_gb must be greater than 0."
  }
}
