# One set of NAT-gateway alarms per NAT.
#
# ErrorPortAllocation — SEV1 signal. Every non-zero value means the NAT is
#   currently refusing outbound connections because it's out of ephemeral
#   source ports. Ties directly to the "how did prod stop being able to
#   reach the internet?" post-mortem.
#
# PacketsDropCount — the NAT is dropping packets due to internal capacity
#   limits (bandwidth or connection state). Also SEV1 if sustained.
#
# BytesOutToDestination — informational / cost signal. NAT egress bandwidth
#   is metered and often the biggest surprise on a bill. A sustained spike
#   also frequently precedes port exhaustion.
#
# alarm_actions defaults to []. When empty the alarms exist and are visible
# in the CloudWatch console but do not notify anyone — wire this to an SNS
# topic ARN owned elsewhere.

resource "aws_cloudwatch_metric_alarm" "nat_port_allocation_errors" {
  for_each = local.az_by_index

  alarm_name          = "${var.project}-${var.environment}-nat-${each.value}-port-allocation-errors"
  alarm_description   = "NAT gateway in ${each.value} is refusing outbound connections due to source-port exhaustion (ErrorPortAllocation > ${var.nat_port_allocation_error_threshold})."
  namespace           = "AWS/NATGateway"
  metric_name         = "ErrorPortAllocation"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.nat_port_allocation_error_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    NatGatewayId = aws_nat_gateway.main[each.key].id
  }

  alarm_actions = var.nat_alarm_actions
  ok_actions    = var.nat_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "nat_packet_drops" {
  for_each = local.az_by_index

  alarm_name          = "${var.project}-${var.environment}-nat-${each.value}-packet-drops"
  alarm_description   = "NAT gateway in ${each.value} is dropping packets — likely at bandwidth or connection-state limit (PacketsDropCount > ${var.nat_packet_drop_threshold} sustained over 5 minutes)."
  namespace           = "AWS/NATGateway"
  metric_name         = "PacketsDropCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  threshold           = var.nat_packet_drop_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    NatGatewayId = aws_nat_gateway.main[each.key].id
  }

  alarm_actions = var.nat_alarm_actions
  ok_actions    = var.nat_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "nat_bytes_out_high" {
  for_each = local.az_by_index

  alarm_name          = "${var.project}-${var.environment}-nat-${each.value}-bytes-out-high"
  alarm_description   = "NAT gateway in ${each.value} egress is unusually high (BytesOutToDestination > ${var.nat_bytes_out_alarm_threshold_gb} GiB per 5-min window, sustained over 15 minutes). Check for runaway workload or cost surprise."
  namespace           = "AWS/NATGateway"
  metric_name         = "BytesOutToDestination"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.nat_bytes_out_alarm_threshold_gb * 1024 * 1024 * 1024
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    NatGatewayId = aws_nat_gateway.main[each.key].id
  }

  alarm_actions = var.nat_alarm_actions
  ok_actions    = var.nat_alarm_actions
}
