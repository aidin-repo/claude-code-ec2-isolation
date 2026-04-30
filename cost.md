# Cost Breakdown

Monthly infrastructure cost for running Claude Code on a shared EC2 instance (Pattern 2 or Pattern 3). Pricing is `us-east-1`, on-demand, as of April 2026.

## Fixed Infrastructure

| Resource | Specification | Monthly Cost |
|----------|---------------|--------------|
| EC2 instance | `t3.2xlarge`, on-demand, 24/7 | ~$245 |
| VPC Interface Endpoints | 5 endpoints (bedrock-runtime, ssm, ssmmessages, ec2messages, sts) | ~$36 |
| VPC Gateway Endpoint | S3 (free) | $0 |
| EBS storage | 200 GB gp3 encrypted | ~$16 |
| Data transfer | HTTPS egress (varies, typical) | ~$1 |
| **Total fixed** | | **~$298/mo** |

Pattern 3 (devcontainer) adds no AWS cost — Docker runs on the same EC2.

## Per-Developer Cost

| Team Size | Total Monthly | Cost per Developer |
|-----------|--------------|--------------------|
| 5 devs | ~$298 | ~$60/dev |
| 15 devs | ~$298 | ~$20/dev |
| 30 devs | ~$298 | ~$10/dev |
| 50 devs | ~$298 (upgrade to `m5.4xlarge`: ~$560) | ~$11/dev |

## Bedrock Model Invocation (Variable)

Billed separately per token. Typical developer usage with Claude Sonnet 4.6:

| Usage Pattern | Input Tokens/day | Output Tokens/day | Monthly Bedrock Cost |
|---------------|-----------------|-------------------|----------------------|
| Light (1-2 hrs/day) | ~500K | ~100K | ~$30/dev |
| Medium (4 hrs/day) | ~2M | ~400K | ~$120/dev |
| Heavy (full-day) | ~5M | ~1M | ~$300/dev |

Prompt caching reduces input costs by up to 90% on repeated context.

## Cost Optimization

- **Instance Scheduler** — stop EC2 outside business hours (~60% savings, ~$100/mo saved on EC2)
- **Reserved Instances** — 1-year commitment saves ~40% on EC2 compute (~$98/mo saved)
- **Right-sizing** — downgrade to `t3.xlarge` (~$122/mo) if workload is light
- **Prompt caching** — use cache breakpoints on large context for up to 90% input token savings

## Example: 30-Developer Team

| Line Item | Monthly |
|-----------|---------|
| EC2 + VPC endpoints + EBS | ~$298 |
| Bedrock (medium usage × 30 devs) | ~$3,600 |
| **Total** | **~$3,898/mo (~$130/dev)** |

With Instance Scheduler + prompt caching applied: **~$1,800/mo (~$60/dev)**.
