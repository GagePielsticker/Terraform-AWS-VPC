# Module: `vpc`

Provisions a three-tier, two-AZ VPC in one AWS account, plus the observability
and alarming that AWS won't give you by default.

## What it creates

- **1× VPC** — `/16`, DNS support + hostnames on.
- **1× Internet Gateway.**
- **6× subnets** — 2 AZs × { public, private-app, private-data }, each a
  deterministic `/20` from the VPC CIDR (`cidrsubnet(vpc, 4, N)`).
- **1× public route table** (shared) — `0.0.0.0/0` → IGW.
- **2× private-app route tables** (per-AZ) — `0.0.0.0/0` → same-AZ NAT.
- **1× private-data route table** (shared) — **no `0.0.0.0/0` route**. Only
  local VPC + S3/DynamoDB endpoints. Deliberate — see below.
- **2× NAT gateways + 2× EIPs** — one per AZ. Reliability tradeoff over
  single-NAT cost saving (per CLAUDE.md).
- **2× gateway VPC endpoints** — S3 and DynamoDB. Free, attached to every
  route table.
- **VPC Flow Logs** → per-VPC CloudWatch log group with `retention_in_days`
  configurable. Traffic type `ALL`, 1-minute aggregation.
- **6× CloudWatch alarms** — three per NAT gateway (`ErrorPortAllocation`,
  `PacketsDropCount`, `BytesOutToDestination`), no default destination.

## Subnet CIDR layout (for `vpc_cidr = "10.10.0.0/16"`)

| Slot | Subnet | AZ | CIDR |
|---|---|---|---|
| 0 | `public[0]`        | `azs[0]` | `10.10.0.0/20`  |
| 1 | `public[1]`        | `azs[1]` | `10.10.16.0/20` |
| 2 | `private_app[0]`   | `azs[0]` | `10.10.32.0/20` |
| 3 | `private_app[1]`   | `azs[1]` | `10.10.48.0/20` |
| 4 | `private_data[0]`  | `azs[0]` | `10.10.64.0/20` |
| 5 | `private_data[1]`  | `azs[1]` | `10.10.80.0/20` |

10 of the 16 possible `/20` slots are unused and reserved for future
expansion (e.g. a transit or secondary-data tier) without renumbering.

## Why the data tier has no NAT/IGW route

The data tier is intentionally unreachable from the internet **and** unable
to reach the internet outbound. Traffic to AWS APIs happens via the S3 and
DynamoDB gateway endpoints; anything else has to be proxied through the
app tier. This makes accidental data exfiltration meaningfully harder and
is the definition of a "data" subnet in the AWS three-tier reference model.

If a workload in the data tier needs to call an AWS API not covered by a
gateway endpoint, add an **interface** VPC endpoint (paid) for that
specific service — do not add a NAT route.

## Usage (from an environment's `terragrunt.hcl`)

```hcl
include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

inputs = {
  vpc_cidr = "10.10.0.0/16"
  azs      = ["us-east-1a", "us-east-1b"]

  # Optional overrides (defaults shown):
  # flow_log_retention_days              = 30
  # nat_alarm_actions                    = ["arn:aws:sns:us-east-1:123456789012:platform-alerts"]
  # nat_port_allocation_error_threshold  = 0
  # nat_packet_drop_threshold            = 0
  # nat_bytes_out_alarm_threshold_gb     = 5
}
```

`project` and `environment` are wired from the root `terragrunt.hcl` and
should not be set per env.

## Inputs

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `project` | `string` | yes | — | Project slug. Wired from root. |
| `environment` | `string` | yes | — | `dev` / `qa` / `prod`. Wired from root. |
| `vpc_cidr` | `string` | yes | — | Must be a `/16`. |
| `azs` | `list(string)` | yes | — | Exactly two distinct AZ names. |
| `flow_log_retention_days` | `number` | no | `30` | CloudWatch retention for flow logs. Must be a CW-supported value. |
| `nat_alarm_actions` | `list(string)` | no | `[]` | SNS topic ARNs for alarm notifications. Empty = observe-only. |
| `nat_port_allocation_error_threshold` | `number` | no | `0` | Alarm on any non-zero ErrorPortAllocation. |
| `nat_packet_drop_threshold` | `number` | no | `0` | Alarm on any sustained PacketsDropCount. |
| `nat_bytes_out_alarm_threshold_gb` | `number` | no | `5` | BytesOutToDestination alarm threshold in GiB per 5-min window. |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the VPC. |
| `vpc_cidr` | CIDR block of the VPC. |
| `internet_gateway_id` | IGW ID. |
| `public_subnet_ids` | Public subnet IDs (per AZ). |
| `private_app_subnet_ids` | Private-app subnet IDs (per AZ). |
| `private_data_subnet_ids` | Private-data subnet IDs (per AZ). |
| `public_route_table_id` | Shared public RT ID. |
| `private_app_route_table_ids` | Private-app RT IDs (per AZ). |
| `private_data_route_table_id` | Shared private-data RT ID. |
| `nat_gateway_ids` | NAT gateway IDs (per AZ). |
| `nat_gateway_public_ips` | NAT public EIPs — use these for partner allow-lists. |
| `s3_endpoint_id` | S3 gateway endpoint ID. |
| `dynamodb_endpoint_id` | DynamoDB gateway endpoint ID. |
| `flow_log_group_name` | CloudWatch log group name for flow logs. |

## NAT alarm reference

Metric ranges (defaults) and what to do when they fire:

| Metric | Threshold | Period × Evals | What it means | First response |
|---|---|---|---|---|
| `ErrorPortAllocation` | `> 0` | 1 min × 1 | NAT is out of ephemeral source ports — outbound connections being refused **right now**. | Check for a workload opening many short-lived connections (e.g. no HTTP keep-alive, unbounded retries). Split traffic across the second AZ's NAT, or add a second NAT per AZ. |
| `PacketsDropCount` | `> 0` (5 min sustained) | 1 min × 5 | NAT is dropping packets at internal capacity limits. | Capacity or connection-count issue. Investigate top talkers in flow logs. |
| `BytesOutToDestination` | `> 5 GiB / 5-min window` (15 min sustained) | 5 min × 3 | Sustained high egress. Cost signal, and often precedes port exhaustion. | Confirm expected. If not, find and stop the runaway workload before it hits the NAT hourly + per-GB bill. |

## Cost sketch (us-east-1, on-demand, as of writing)

- VPC / IGW / route tables / subnets — free.
- NAT gateway — **~$32/mo per NAT** (hourly) + **$0.045/GB** processed.
  Two NATs = ~$64/mo baseline before any traffic.
- Gateway endpoints (S3, DynamoDB) — free.
- Flow logs to CloudWatch — **~$0.50/GB** ingested + **~$0.03/GB-mo**
  stored.

The largest single line is NAT hourly + data-processing — that's what the
`nat_bytes_out_high` alarm exists to catch before it becomes a bill
surprise.

## Notes

- **Two AZs by design.** Growing to 3 AZs is not a config flip — you'd walk
  the CIDR math again, add a third NAT + EIP + route table, and change the
  `azs` validation.
- **Public subnets have `map_public_ip_on_launch = true`.** Anything you
  launch in a public subnet gets a public IP unless the launch config
  overrides it. If that's not what you want, put the workload in the
  private-app tier — that's what it's for.
- **State impact.** `terragrunt destroy` on this module tears down the
  network every workload in the account sits on. It's a break-glass action.
