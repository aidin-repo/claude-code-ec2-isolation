# Claude Code on EC2 — Network-Isolated Deployment

> **⚠️ This is a proof of concept.** Test thoroughly and understand every security layer before rolling out to your team. You can use your preferred coding tools to deploy and customize — including [Kiro](https://kiro.dev) and [Claude Code on Bedrock](https://code.claude.com/docs/en/amazon-bedrock).

Deploy Claude Code on a shared EC2 instance with per-user isolation, Amazon Bedrock integration, and defense-in-depth security. Designed for regulated environments (healthcare, finance) where developers must not access production databases containing PHI/PII.

## How It Works

Developers connect to a shared EC2 instance via SSM Session Manager (no SSH, no inbound ports). Each developer gets their own Linux user account with isolated home directory, Claude Code installation, and AWS SSO credentials. Four independent security layers prevent access to production databases — even if one layer is bypassed, the others hold.

```mermaid
graph LR
  subgraph Laptop["Developer Laptop"]
    Terminal["🖥️ Terminal"]
    Browser["🌐 Browser\n(SSO auth)"]
  end

  subgraph AWS["AWS Account"]
    subgraph VPC["VPC (HTTPS outbound only)"]
      subgraph EC2["EC2 (Ubuntu 24.04)"]
        User1["👤 user1\nClaude Code"]
        User2["👤 user2\nClaude Code"]
        UserN["👤 ..."]
      end
      subgraph Endpoints["VPC Endpoints (PrivateLink)"]
        BR["bedrock-runtime"]
        SSM["ssm / ssmmessages\nec2messages"]
        STS["sts"]
        S3["s3 (gateway)"]
      end
    end
    IDC["IAM Identity Center\nBedrockClaudeCode\npermission set"]
  end

  Terminal -- "SSM Session\n(no SSH, no inbound)" --> EC2
  EC2 -- "device code flow" --> Browser
  User1 & User2 & UserN --> Endpoints
  IDC -. "bedrock:Invoke*\ndeny all databases" .-> EC2
```

## Security Layers (Defense-in-Depth)

| Layer | Control | What It Blocks | Can Developers Bypass? |
|-------|---------|----------------|------------------------|
| **Security Group** | HTTPS/443 + HTTP/80 outbound only | All DB ports (3306, 5432, 27017, 6379) | No — hypervisor enforced |
| **IAM Policy** | Deny all database services | `rds:*`, `dynamodb:*`, `redshift:*`, `neptune-db:*`, etc. | No — AWS control plane enforced |
| **Claude Code Hook** | Pre-hook blocks DB commands | `psql`, `mysql`, `mongosh`, connection strings, `aws rds` CLI | Soft guard — SG + IAM are the hard controls |
| **OS Isolation** | `hidepid=invisible`, `umask 077`, no sudo | Users can't see each other's processes or files | No — root-owned config |
| **Identity** | IAM Identity Center SSO per-user | Shared credentials | Individual audit trail via CloudTrail |

## Quick Start

### Prerequisites

- AWS CLI v2 with [SSM Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- Bedrock model access enabled — [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess)
- IAM Identity Center configured with a `BedrockClaudeCode` permission set (see [SSO Setup](#sso-setup) below)

### 1. Deploy

The template creates everything — VPC, subnet, security groups, IAM role, VPC endpoints, EC2 instance. No existing infrastructure required.

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name claude-code-ec2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    DeveloperUsers=jane.doe,john.smith \
    SsoStartUrl=https://your-org.awsapps.com/start
```

Or bring your own VPC:

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name claude-code-ec2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    VpcId=vpc-xxxx \
    SubnetId=subnet-xxxx \
    DeveloperUsers=jane.doe,john.smith \
    SsoStartUrl=https://your-org.awsapps.com/start
```

Wait ~5 minutes for setup to complete. Check progress:

```bash
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name claude-code-ec2 \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)

# Check setup log (look for "Setup Complete" at the end)
aws ssm start-session --target $INSTANCE_ID
# then: sudo tail -f /var/log/claude-code-setup.log
```

### 2. Connect and Use

```bash
# Connect via SSM (no SSH needed)
aws ssm start-session --target $INSTANCE_ID

# Switch to your Linux user
sudo su - jane.doe

# Authenticate with SSO (device code flow — works on headless EC2)
auth
# → Opens a URL + code — paste into your laptop browser, authenticate with your IdP

# Launch Claude Code
claude
```

### 3. Verify Security Controls

Run these tests before rolling out to your team:

```bash
# Security group blocks database ports
timeout 3 bash -c "echo > /dev/tcp/google.com/5432" 2>&1   # Should timeout

# IAM denies database API calls
aws rds describe-db-instances                                # Should return AccessDenied

# Hook blocks database commands (inside a Claude Code session)
# Ask Claude to run: psql -h mydb.example.com
# → Should be blocked: "Database client connections are blocked by policy"

# Cross-user isolation
su - jane.doe -c "ls /home/john.smith/"                     # Should return Permission denied
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `DeveloperUsers` | No | `user1,user2` | Comma-separated Linux usernames to create |
| `SsoStartUrl` | No | *(empty)* | IAM Identity Center start URL — enables SSO profile + `auth` helper |
| `SsoRoleName` | No | `BedrockClaudeCode` | Permission set name in IAM Identity Center |
| `VpcId` | No | *(empty)* | Existing VPC ID — leave empty to create a new VPC |
| `SubnetId` | No | *(empty)* | Existing subnet ID — leave empty to create a new subnet |
| `InstanceType` | No | `t3.2xlarge` | EC2 instance type |
| `KeyPairName` | No | *(empty)* | SSH key pair — SSM is primary access, leave empty to skip |
| `RouteTableId` | No | *(empty)* | Route table for S3 gateway endpoint — only needed with existing VPC |
| `OtelEndpoint` | No | *(empty)* | OpenTelemetry collector URL — leave empty to skip telemetry |
| `AmiId` | No | Ubuntu 24.04 (auto) | AMI auto-resolved from AWS SSM public parameter |


## SSO Setup

Create a permission set in IAM Identity Center that grants Bedrock access and denies database services:

```bash
SSO_INSTANCE_ARN="arn:aws:sso:::instance/<your-sso-instance-id>"

# Create permission set (12-hour session for full workday)
PS_ARN=$(aws sso-admin create-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --name "BedrockClaudeCode" \
  --session-duration "PT12H" \
  --query 'PermissionSet.PermissionSetArn' \
  --output text)

# Attach inline policy
aws sso-admin put-inline-policy-to-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --inline-policy '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "AllowBedrock",
        "Effect": "Allow",
        "Action": [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListInferenceProfiles"
        ],
        "Resource": [
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
          "arn:aws:bedrock:*:*:inference-profile/*"
        ]
      },
      {
        "Sid": "DenyAllDatabases",
        "Effect": "Deny",
        "Action": ["rds:*", "dynamodb:*", "redshift:*", "neptune-db:*", "docdb-elastic:*", "elasticache:*", "memorydb:*"],
        "Resource": "*"
      },
      {
        "Sid": "DenyEC2NetworkChanges",
        "Effect": "Deny",
        "Action": [
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress"
        ],
        "Resource": "*"
      }
    ]
  }'

# Assign to a user
aws sso-admin create-account-assignment \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$PS_ARN" \
  --principal-id "<user-id-from-identity-store>" \
  --principal-type USER \
  --target-id "<your-account-id>" \
  --target-type AWS_ACCOUNT
```

The template automatically configures each user's `~/.aws/config` with the SSO profile and deploys the `auth` helper at `/usr/local/bin/auth`. Developers just run `auth` and follow the device code flow.

## What the Template Creates

| Resource | Description |
|----------|-------------|
| VPC + Subnet + IGW + Route Table | Created if `VpcId` is empty; skipped if you bring your own |
| EC2 Instance | Ubuntu 24.04, 200GB encrypted gp3 EBS |
| Security Group | HTTPS/443 + HTTP/80 outbound only, no inbound |
| IAM Role | Bedrock invoke + SSM access, explicit deny on all database services + SG changes |
| VPC Endpoints | Bedrock Runtime, SSM, SSMMessages, EC2Messages, STS (interface) + S3 (gateway) |
| SSM Parameter | `/claude-code/users` — developer user list for automated provisioning |

## What UserData Configures on the Instance

1. **System packages** — bubblewrap, socat, jq, git, ripgrep, AWS CLI v2
2. **OS hardening** — `hidepid=invisible` on /proc, `umask 077` for all users
3. **Managed settings** at `/etc/claude-code/managed-settings.json` — Bedrock config, OTel (if provided), deny sudo
4. **Pre-hook** at `/opt/claude-hooks/block-db-access.sh` — blocks database clients, connection strings, AWS database CLI
5. **SSO profile** at `~/.aws/config` per user + `/usr/local/bin/auth` helper (if `SsoStartUrl` provided)
6. **OTel identity** at `/etc/profile.d/claude-otel.sh` — injects `developer.name` per user
7. **Claude Code** installed for each user
8. **Hourly user sync** from SSM Parameter Store via cron

## User Management

### Add a user

```bash
# 1. Update SSM Parameter Store
aws ssm put-parameter \
  --name /claude-code/users \
  --value "jane.doe,john.smith,new.user" \
  --type String --overwrite

# 2. Trigger sync (or wait for hourly cron)
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/opt/scripts/sync-users.sh"]'

# 3. Assign the BedrockClaudeCode permission set to the new user in IAM Identity Center
```

### Update Claude Code

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["for user in $(cut -d: -f1 /etc/passwd | grep -v root | grep -v nobody); do su - $user -c \"npm install -g @anthropic-ai/claude-code@latest\" 2>/dev/null; done"]'
```

## Monitoring

| System | Per-User Identity |
|--------|-------------------|
| **CloudTrail** | Automatic via SSO — developer email in assumed role ARN |
| **OTel** | `OTEL_RESOURCE_ATTRIBUTES="developer.name=$(whoami)"` injected at login |
| **Bedrock Invocation Logs** | Tied to assumed role session name |
| **SSM Session Logs** | Tied to IAM principal that started the session |

## Optional: Devcontainer Isolation

For maximum isolation, run Claude Code inside Docker containers with an iptables-based domain allowlist. See `setup-devcontainer.sh`.

```bash
sudo bash setup-devcontainer.sh
/opt/claude-devcontainer/launch.sh
```

## Cost

| Resource | Monthly Cost |
|----------|-------------|
| EC2 t3.2xlarge (on-demand, 24/7) | ~$245 |
| VPC Endpoints (5 interface + 1 gateway) | ~$37 |
| EBS 200GB gp3 | ~$16 |
| **Total** | **~$298/mo (~$10/dev for 30 devs)** |

Bedrock invocation costs are separate. Use [Instance Scheduler](https://aws.amazon.com/solutions/implementations/instance-scheduler-on-aws/) to stop EC2 outside business hours (~60% savings).

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| UserData didn't complete | `sudo tail -f /var/log/claude-code-setup.log` — check for errors |
| `auth` timeout | Verify laptop can reach SSO domain; check permission set assignment |
| Claude Code hangs | Credentials expired — run `auth` again, restart `claude` |
| Access Denied on Bedrock | `aws sts get-caller-identity --profile claudecode-sso` — verify model enabled in Bedrock console |
| Hook not blocking | Expected in terminal — hooks only apply inside Claude Code. SG + IAM are the hard controls. |

## Repository Contents

| File | Purpose |
|------|---------|
| `template.yaml` | CloudFormation template — everything in one file |
| `connect-sso.sh` | Connection helper script for SSM + SSO |
| `setup-devcontainer.sh` | Optional: Docker-based isolation with iptables firewall |
| `blog-claude-code-ec2-isolation.md` | Detailed blog post explaining the architecture and security model |

## References

- [Protecting Sensitive Data When Using Claude Code on Amazon Bedrock](https://builder.aws.com/content/3BDrMDCZK6WVhQEA2amur9zj51q/protecting-sensitive-data-when-using-claude-code-on-amazon-bedrock)
- [Claude Code Deployment Patterns with Amazon Bedrock](https://aws.amazon.com/blogs/machine-learning/claude-code-deployment-patterns-and-best-practices-with-amazon-bedrock/)
- [Guidance for Claude Code with Amazon Bedrock](https://github.com/aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock)
- [Claude Code Hooks Documentation](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [Claude Code Bedrock Documentation](https://code.claude.com/docs/en/amazon-bedrock)
- [Claude Code Devcontainer Reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
