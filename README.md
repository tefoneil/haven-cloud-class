# Haven Cloud Architecture

> A hands-on AWS deployment course built from a real production migration.

**Not a tutorial.** This is a documented, step-by-step record of deploying a production Python application to AWS — including every command, every mistake, and every lesson learned.

## What is Haven?

Haven is a 34-loop async Python daemon that processes live crypto market data from 47 sources (Telegram channels, on-chain wallet tracking, DexScreener, CoinGecko, Helius, and more). It runs 24/7, ingesting ~30,000 messages/month, tracking ~40,000 wallet signals, and generating trading intelligence across multiple asset lanes.

It was running on a MacBook. That was a problem.

## Why This Course Exists

When your trading daemon crashes because your laptop went to sleep — and you lose a database to corruption for the second time — you migrate to the cloud. This course documents that migration from "daemon on a laptop" to "production-ready AWS deployment."

Along the way, you learn VPC networking, EC2 compute, systemd process management, S3 backup automation, CloudWatch monitoring, SSM secrets management, IAM security hardening, and operational dashboards — all in the context of a real application solving real problems.

## What Makes This Different

- **Real application, real problems.** Not a hello-world app. A 7,000-line daemon with 70+ database tables, async event loops, and live API integrations.
- **Real mistakes, real fixes.** SQLite version mismatches, SIGTERM timeouts, IAM permission loops, DB corruption recovery. The gotchas are the most valuable part.
- **Production patterns.** WAL-safe backups, heartbeat monitoring, SSM secret injection, least-privilege IAM, hysteresis-based health checks.

## Modules

| Module | Topic | AWS Services |
|--------|-------|-------------|
| [00 - Why Cloud](00-why-cloud/) | The problem and the plan | — |
| [01 - VPC & Compute](01-vpc-and-compute/) | Networking and EC2 | VPC, EC2, Security Groups |
| [02 - Application Deployment](02-application-deployment/) | Getting code running on a server | EC2, SSH, SCP |
| [03 - Process Management](03-process-management/) | Surviving reboots and crashes | systemd |
| [04 - Storage & Backups](04-storage-and-backups/) | Automated database backups | S3, IAM Roles |
| [05 - Monitoring & Alerting](05-monitoring-and-alerting/) | Knowing when things break | CloudWatch, SNS |
| [06 - Secrets Management](06-secrets-management/) | Getting secrets off disk | SSM Parameter Store |
| [07 - Security Hardening](07-security-hardening/) | Least privilege and defense in depth | IAM, fail2ban |
| [08 - Operational Dashboards](08-operational-dashboards/) | Single-pane-of-glass visibility | CloudWatch Dashboards |
| [Capstone](capstone/) | Final assessment and architecture review | All services |

## Tech Stack

- **Application:** Python 3.12, asyncio, Poetry, SQLite (WAL mode)
- **Cloud:** AWS (EC2 t3.small, Ubuntu 24.04, us-east-1)
- **Infrastructure:** AWS CLI, systemd, cron, bash scripting
- **Cost:** ~$20/month (EC2 + EBS + S3 + Elastic IP)

## How to Use This Course

Each module follows a consistent structure:

1. **The Problem** — A real pain point from running Haven locally
2. **The Concept** — What the AWS service is and why it exists
3. **The Build** — Step-by-step commands with annotations
4. **The Gotcha** — What went wrong and how it was fixed
5. **The Result** — Proof it works with verification commands
6. **Key Takeaways** — 3-5 bullets summarizing what was learned

---

*Built by Brandon Derricott as part of the Haven crypto intelligence project. Deployed March 2026.*
