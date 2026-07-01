include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

inputs = {
  vpc_cidr = "10.10.0.0/16"

  # Optional overrides (defaults shown):
  # azs                                  = ["us-east-1a", "us-east-1b"]  # auto-derived from root region
  # flow_log_retention_days              = 30
  # nat_alarm_actions                    = []    # SNS topic ARNs
  # nat_port_allocation_error_threshold  = 0
  # nat_packet_drop_threshold            = 0
  # nat_bytes_out_alarm_threshold_gb     = 5
}
