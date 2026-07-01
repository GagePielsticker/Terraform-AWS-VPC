<div align="center">

# 🌐 Terraform / Terragrunt — AWS VPC

**Three-tier, two-AZ VPC per environment — with S3/DynamoDB endpoints, flow logs, and NAT alarms out of the box.**

[![Terraform](https://img.shields.io/badge/Terraform-1.10.0-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Terragrunt](https://img.shields.io/badge/Terragrunt-0.67.0-2E7EED?logo=terraform&logoColor=white)](https://terragrunt.gruntwork.io/)
[![AWS](https://img.shields.io/badge/AWS-OIDC-FF9900?logo=amazonaws&logoColor=white)](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc.html)
[![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-CI%2FCD-2088FF?logo=githubactions&logoColor=white)](.github/workflows)
[![Trivy](https://img.shields.io/badge/Trivy-IaC%20Scan-1904DA?logo=aquasec&logoColor=white)](.github/workflows/trivy.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

</div>

---

## ✨ What this repo does

Deploys one production-shaped AWS VPC per environment (`dev`, `qa`, `prod`), each in its own AWS account, following the standard three-tier reference pattern. Batteries included: gateway endpoints, flow logs, and NAT-gateway alarms — no follow-up "day-2" PR needed to make the network observable.

### 🏛️ Two AZs × three tiers = six subnets

| Tier | Route to internet? | Purpose |
|---|---|---|
| **`public`** | `0.0.0.0/0` → IGW | Load balancers, bastions, NAT gateways. |
| **`private-app`** | `0.0.0.0/0` → same-AZ NAT | ECS/EKS tasks, EC2 workers, Lambda VPC ENIs. |
| **`private-data`** | **None** (local + S3/DDB endpoints only) | RDS, ElastiCache, MSK. Reachable only from the app tier via security groups. |

Subnet sizing: `/20` each, deterministically derived from the VPC's `/16` — six of sixteen `/20` slots consumed, ten reserved for future tiers.

### 🚦 NAT & internet path

- **One NAT gateway per AZ** with its own EIP. Costs ~2× a single-NAT design, but survives an AZ failure of the NAT itself (Well-Architected Reliability > Cost).
- **Public subnets** share one route table (all → the same IGW).
- **Private-app subnets** each have a route table pointing at their **own AZ's** NAT — a NAT outage in one AZ never blackholes the other AZ's egress.
- **Private-data subnets** share one route table with **no default route**. Deliberate — see [module README](terraform/modules/vpc/README.md#why-the-data-tier-has-no-natigw-route).

### 🚪 Free gateway VPC endpoints

- `aws_vpc_endpoint` for **S3** (`com.amazonaws.<region>.s3`)
- `aws_vpc_endpoint` for **DynamoDB** (`com.amazonaws.<region>.dynamodb`)

Both `Gateway`-type, both **free** (no hourly, no per-GB), both attached to every route table so any workload — including the data tier — reaches S3/DDB over the AWS backbone without touching NAT.

### 🪵 VPC Flow Logs → CloudWatch

- One CloudWatch log group per VPC (`/aws/vpc/<project>-<env>/flow-logs`).
- Traffic type `ALL` (both ACCEPT and REJECT — REJECTs are the ones that matter in an incident).
- Retention default **30 days**, tunable via `flow_log_retention_days`.
- IAM role scoped to the log group ARN only.

### 🚨 NAT gateway alarms

Three CloudWatch alarms per NAT (six total across two AZs):

| Metric | Default threshold | Meaning |
|---|---|---|
| `ErrorPortAllocation` | `> 0` (1 min) | **Source-port exhaustion.** Outbound connections being refused *right now* — SEV1. |
| `PacketsDropCount` | `> 0` sustained 5 min | NAT dropping packets at internal capacity limits. |
| `BytesOutToDestination` | `> 5 GiB / 5-min` sustained 15 min | Egress volume unusually high — cost signal, and often precedes port exhaustion. |

Alarms have **no default destination** — `nat_alarm_actions` defaults to `[]`. Wire that input to an SNS topic ARN when you have one (e.g. a future `terraform-aws-notifications` repo). Alarms without actions still exist and are visible in the console.

### 🧰 Everything else

- 🔁 **DRY config** via one root `terragrunt.hcl` — backend, provider, and tags in one place.
- 🤖 **Plan on PR, apply on merge** — sticky per-env plan comments, per-env apply concurrency.
- 🔐 **OIDC-only** to AWS — no long-lived access keys anywhere.
- 🛡️ **IaC scanning** on every PR via Trivy (HIGH/CRITICAL gate).

---

## 📁 Repository layout

```text
terraform/
├── terragrunt.hcl                 # 🔧 Shared root config (backend, provider, tags, common inputs)
├── environments/
│   ├── dev/                       # vpc_cidr = 10.10.0.0/16
│   ├── qa/                        # vpc_cidr = 10.20.0.0/16
│   └── prod/                      # vpc_cidr = 10.30.0.0/16
│       ├── env.hcl
│       └── terragrunt.hcl
└── modules/
    └── vpc/                       # 🌐 The single reusable module
        ├── main.tf                # VPC + IGW
        ├── subnets.tf             # 6 subnets + route tables + associations
        ├── nat.tf                 # 2 EIPs + 2 NAT gateways + private-app routes
        ├── endpoints.tf           # S3 + DynamoDB gateway endpoints
        ├── flow_logs.tf           # CW log group + IAM role + aws_flow_log
        ├── alarms.tf              # 3 alarms × 2 NATs = 6 alarms
        ├── variables.tf
        ├── outputs.tf
        └── README.md

.github/workflows/
├── terraform-plan.yml
├── terraform-apply.yml
└── trivy.yml
```

---

## 📚 Table of contents

1. [Subnet layout & CIDR math](#1--subnet-layout--cidr-math)
2. [Things you MUST change before deploying](#2-️-things-you-must-change-before-deploying)
3. [AWS setup — OIDC & IAM](#3-️-aws-setup--letting-github-actions-assume-the-roles)
4. [GitHub setup](#4--github-setup)
5. [Local usage](#5--local-usage)
6. [How CI decides what to deploy](#6--how-the-ci-decides-what-to-deploy)
7. [Onboarding checklist](#7--onboarding-checklist)

---

## 1. 🧮 Subnet layout & CIDR math

Each subnet is `cidrsubnet(var.vpc_cidr, 4, N)` — the N-th `/20` inside the VPC `/16`. For `vpc_cidr = "10.10.0.0/16"`:

| Slot | Subnet | AZ | CIDR |
|---|---|---|---|
| 0 | `public[0]`        | `azs[0]` | `10.10.0.0/20`  |
| 1 | `public[1]`        | `azs[1]` | `10.10.16.0/20` |
| 2 | `private_app[0]`   | `azs[0]` | `10.10.32.0/20` |
| 3 | `private_app[1]`   | `azs[1]` | `10.10.48.0/20` |
| 4 | `private_data[0]`  | `azs[0]` | `10.10.64.0/20` |
| 5 | `private_data[1]`  | `azs[1]` | `10.10.80.0/20` |

Slots 6–15 (`10.10.96.0/20` through `10.10.240.0/20`) are unused and reserved — you can add a transit or secondary-data tier later without renumbering anything.

Per-env defaults use non-overlapping ranges so a future Transit Gateway or VPC peering will Just Work:

| Env | VPC CIDR |
|---|---|
| `dev`  | `10.10.0.0/16` |
| `qa`   | `10.20.0.0/16` |
| `prod` | `10.30.0.0/16` |

---

## 2. ⚠️ Things you MUST change before deploying

> 🔍 **Rule of thumb:** `grep -R REPLACE_ME_ .` — every match is a placeholder you need to fill in. The table below is the complete list.

| # | Placeholder | File | What to set it to |
|---|---|---|---|
| 1 | `REPLACE_ME_PROJECT_NAME` | [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl) | Short project slug (e.g. `platform-vpc`). Used in the state-file key, every resource name, and tags. |
| 2 | `REPLACE_ME_TEAM_NAME` | [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl) | Owning team name. Applied as a default tag. |
| 3 | `REPLACE_ME_DEV_ACCOUNT_ID` | both workflows in [`.github/workflows/`](.github/workflows/) | 12-digit AWS account ID for `dev`. |
| 4 | `REPLACE_ME_QA_ACCOUNT_ID` | both workflows in [`.github/workflows/`](.github/workflows/) | 12-digit AWS account ID for `qa`. |
| 5 | `REPLACE_ME_PROD_ACCOUNT_ID` | both workflows in [`.github/workflows/`](.github/workflows/) | 12-digit AWS account ID for `prod`. |
| 6 | `REPLACE_ME_GHA_ROLE` | both workflows in [`.github/workflows/`](.github/workflows/) | IAM role name that the GitHub Actions OIDC principal assumes. See [section 3](#3-️-aws-setup--letting-github-actions-assume-the-roles). |

### 2a. 📝 Repo-wide config — [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl)

| Local | Current value | What to set it to |
|---|---|---|
| `project` | `REPLACE_ME_PROJECT_NAME` | Short project slug. |
| `team` | `REPLACE_ME_TEAM_NAME` | Owning team name. |
| `region` | `us-east-1` | AWS region to deploy into. `azs` auto-derives as `["<region>a", "<region>b"]`. See the [region-change note below](#-changing-the-region) — you also need to update the two workflow files. |

Also confirm the state bucket name pattern is what you want:

```hcl
bucket = "${local.environment}-infra-tf-state"
```

> 🪣 **The bucket must already exist** in each account before the first `terragrunt init` — Terragrunt won't create it for you with this config.

### 2b. 🌍 Per-env `vpc_cidr` (and optional `azs` override)

`azs` is derived automatically at the root as `["${region}a", "${region}b"]` from [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl)'s `region` local, so the only required per-env input is the CIDR. Override `azs` per env only if you need to skip a specific AZ.

| Env | File | Current `vpc_cidr` | Effective `azs` |
|---|---|---|---|
| `dev`  | [`environments/dev/terragrunt.hcl`](terraform/environments/dev/terragrunt.hcl)   | `10.10.0.0/16` | `["<region>a", "<region>b"]` |
| `qa`   | [`environments/qa/terragrunt.hcl`](terraform/environments/qa/terragrunt.hcl)     | `10.20.0.0/16` | `["<region>a", "<region>b"]` |
| `prod` | [`environments/prod/terragrunt.hcl`](terraform/environments/prod/terragrunt.hcl) | `10.30.0.0/16` | `["<region>a", "<region>b"]` |

Full block for reference (all overrides shown with their defaults):

```hcl
inputs = {
  vpc_cidr = "10.10.0.0/16"

  # Optional overrides (defaults shown):
  # azs                                  = ["us-east-1a", "us-east-1b"]  # auto-derived from root region
  # flow_log_retention_days              = 30
  # nat_alarm_actions                    = []    # e.g. ["arn:aws:sns:us-east-1:123456789012:platform-alerts"]
  # nat_port_allocation_error_threshold  = 0
  # nat_packet_drop_threshold            = 0
  # nat_bytes_out_alarm_threshold_gb     = 5
}
```

> ⚠️ **Pick AZs deliberately per env.** AZ-name-to-physical-AZ mapping is *account-specific* (an `us-east-1a` in account A is not necessarily the same physical DC as `us-east-1a` in account B). This matters when you set up cross-account peering or Transit Gateway.

<a id="-changing-the-region"></a>

> 🌐 **Changing the region.** Three files:
> 1. [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl) — the `region` local. Drives the provider, state config, and default `azs`.
> 2. [`.github/workflows/terraform-plan.yml`](.github/workflows/terraform-plan.yml) — `AWS_REGION`.
> 3. [`.github/workflows/terraform-apply.yml`](.github/workflows/terraform-apply.yml) — `AWS_REGION`.
>
> Also verify: the S3 state bucket exists in the new region, and the new region actually has `a` / `b` AZs (all commercial regions do; a handful of edge cases may need an explicit `azs` override per env).

### 2c. 🔑 Workflow role map — [`terraform-plan.yml`](.github/workflows/terraform-plan.yml) & [`terraform-apply.yml`](.github/workflows/terraform-apply.yml)

Both files define an `AWS_ROLE_ARNS` map keyed by environment folder name:

```yaml
AWS_ROLE_ARNS: |
  {
    "dev":  "arn:aws:iam::REPLACE_ME_DEV_ACCOUNT_ID:role/REPLACE_ME_GHA_ROLE",
    "qa":   "arn:aws:iam::REPLACE_ME_QA_ACCOUNT_ID:role/REPLACE_ME_GHA_ROLE",
    "prod": "arn:aws:iam::REPLACE_ME_PROD_ACCOUNT_ID:role/REPLACE_ME_GHA_ROLE"
  }
```

Both files must stay in sync. Adding a new environment means adding a matching entry here — missing map entries fail fast by design.

---

## 3. ☁️ AWS setup — letting GitHub Actions assume the roles

Do this once **per AWS account** (`dev`, `qa`, `prod`).

### 3a. 🪪 Create the GitHub OIDC provider in the account

If not already present:

- **Provider URL:** `https://token.actions.githubusercontent.com`
- **Audience:** `sts.amazonaws.com`

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"] # any value; AWS ignores it since 2023
}
```

### 3b. 👤 Create the IAM role that GitHub will assume

**Trust policy** — pin the repo + event/branch:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:<ORG>/<REPO>:pull_request",
            "repo:<ORG>/<REPO>:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
```

**Recommended split:**

| Role type | Trust subs | AWS permissions |
|---|---|---|
| 🔎 **Plan role** (PR runs) | `pull_request` | Read-only across the service surface below + state bucket R/W |
| 🚀 **Apply role** (merge to main) | `ref:refs/heads/main` | Minimum policy below + state bucket R/W |

**Minimum apply-role policy** (everything the `vpc` module actually calls):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VpcAndNetworking",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
        "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
        "ec2:AllocateAddress", "ec2:ReleaseAddress",
        "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
        "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint",
        "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs",
        "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:Describe*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "FlowLogsIamRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/<PROJECT>-<ENV>-vpc-flow-logs"
    },
    {
      "Sid": "FlowLogsLogGroup",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup", "logs:DeleteLogGroup",
        "logs:DescribeLogGroups", "logs:ListTagsLogGroup",
        "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
        "logs:TagResource", "logs:UntagResource"
      ],
      "Resource": "arn:aws:logs:*:<ACCOUNT_ID>:log-group:/aws/vpc/<PROJECT>-<ENV>/*"
    },
    {
      "Sid": "NatAlarms",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
        "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
        "cloudwatch:TagResource", "cloudwatch:UntagResource"
      ],
      "Resource": "arn:aws:cloudwatch:*:<ACCOUNT_ID>:alarm:<PROJECT>-<ENV>-nat-*"
    }
  ]
}
```

Substitute `<ACCOUNT_ID>`, `<PROJECT>` (from [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl)), and `<ENV>` (`dev`/`qa`/`prod`).

The plan role needs the `Describe*` / `Get*` / `List*` subset of the above.

### 3c. 🗄️ Attach the state-backend permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::<ENV>-infra-tf-state",
        "arn:aws:s3:::<ENV>-infra-tf-state/*"
      ]
    }
  ]
}
```

With `use_lockfile = true` in the root `terragrunt.hcl`, the lock is a `.tflock` object in the same bucket — no DynamoDB required.

### 3d. 📥 Paste the role ARNs into the workflows

Put each account's role ARN into `AWS_ROLE_ARNS` in both [`terraform-plan.yml`](.github/workflows/terraform-plan.yml) and [`terraform-apply.yml`](.github/workflows/terraform-apply.yml).

---

## 4. 🐙 GitHub setup

> 🛡️ **Branch protection on `main`** — require these checks before merge:
> - `Format check`
> - `Plan <env>` (per affected environment)
> - `Trivy IaC scan`
>
> The merge itself is the approval gate — apply runs automatically for every affected env after merge.

---

## 5. 💻 Local usage

Once the placeholders are replaced and you're authenticated into the account whose env you're targeting:

```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>

cd terraform/environments/dev
terragrunt init
terragrunt plan     # first run: expect ~30 resources (VPC, IGW, 6 subnets, 4 route tables, 8 associations, 2 EIPs, 2 NATs, 2 NAT routes, 2 endpoints, log group, IAM role/policy, flow log, 6 alarms)
terragrunt apply
```

> ⏱️ **NAT gateways take 2–3 minutes each to create.** First `apply` will feel slow — that's normal.

---

## 6. 🧭 How the CI decides what to deploy

Both plan and apply workflows share the same detection logic:

| Files changed | Result |
|---|---|
| `terraform/environments/<env>/**` | 🎯 Plan/apply that env only |
| `terraform/modules/**` | 📦 Plan/apply **every** env (modules are shared) |
| `terraform/terragrunt.hcl` | 🌍 Plan/apply **every** env (root config affects all) |

> 🎛️ The apply workflow additionally accepts a `workflow_dispatch` input to force-apply a comma-separated list of environments.

---

## 7. ✅ Onboarding checklist

- [ ] Replace `project` and `team` in [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl)
- [ ] Confirm/change `region` in [`terraform/terragrunt.hcl`](terraform/terragrunt.hcl) — if changing it, also update `AWS_REGION` in [both workflows](#-changing-the-region)
- [ ] Confirm the state bucket name pattern (`<env>-infra-tf-state`) matches your org
- [ ] Set the real `vpc_cidr` for each of [dev](terraform/environments/dev/terragrunt.hcl) / [qa](terraform/environments/qa/terragrunt.hcl) / [prod](terraform/environments/prod/terragrunt.hcl) — verify the three `/16`s don't overlap each other or any other network you might peer with
- [ ] Override `azs` in any env that needs to skip a bad AZ (rare)
- [ ] Decide on `flow_log_retention_days` per env (default `30`)
- [ ] Create the S3 state bucket (`<env>-infra-tf-state`) in each AWS account
- [ ] Create the GitHub OIDC provider + per-env IAM plan/apply roles in each account (see [section 3](#3-️-aws-setup--letting-github-actions-assume-the-roles))
- [ ] Put role ARNs into `AWS_ROLE_ARNS` in **both** [`terraform-plan.yml`](.github/workflows/terraform-plan.yml) and [`terraform-apply.yml`](.github/workflows/terraform-apply.yml)
- [ ] Turn on branch protection for `main` with the required checks listed in [section 4](#4--github-setup)
- [ ] Verify: open a throwaway PR that bumps `dev`'s `flow_log_retention_days`, confirm `Plan dev` comments on the PR, then merge and confirm `Apply dev` runs green
- [ ] Later: point `nat_alarm_actions` at a real SNS topic ARN so the NAT alarms actually notify someone

---

<div align="center">

Made with 🧱 Terraform · 🧬 Terragrunt · ☁️ AWS · 🐙 GitHub Actions

</div>
