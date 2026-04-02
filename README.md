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
### Part 1: The Real Deployment
*What we actually built — every command, every mistake.*

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

### Part 2: The What-If Expansion
*How Haven would use these services — build in a lab VPC, teardown after.*

| Module | Topic | AWS Services | SAA-C03 Domain |
|--------|-------|-------------|----------------|
| [09 - Databases](09-databases/) | "Haven outgrows SQLite" | RDS, Aurora, DynamoDB | Resilient, High-Performing |
| [10 - Serverless](10-serverless/) | "Briefings go serverless" | Lambda, API Gateway | High-Performing, Cost |
| [11 - Load Balancing](11-load-balancing/) | "Dashboard needs to scale" | ALB, ASG, Launch Templates | Resilient, High-Performing |
| [12 - DNS & CDN](12-dns-and-cdn/) | "Give Haven a domain" | Route 53, CloudFront | Resilient, High-Performing |
| [13 - Messaging](13-messaging/) | "Haven goes event-driven" | SQS, SNS, EventBridge | Resilient, High-Performing |
| [14 - Containers](14-containers/) | "Dockerize Haven" | Docker, ECR, ECS, Fargate | High-Performing, Cost |

### Part 3: Exam Readiness
*Think like an architect — SAA-C03 certification prep.*

| Module | Topic | Focus |
|--------|-------|-------|
| [15 - Advanced Security](15-advanced-security/) | "Protect Haven's APIs" | KMS, WAF, Shield, GuardDuty (30% of exam) |
| [16 - Exam Mastery](16-exam-mastery/) | "Think like an architect" | Well-Architected Framework, 20 practice questions |
| [Capstone](capstone/) | Final assessment | 40-question quiz, study guide, architecture review |

## Tech Stack

- **Application:** Python 3.12, asyncio, Poetry, SQLite (WAL mode)
- **Cloud:** AWS (EC2 t3.small, Ubuntu 24.04, us-east-1)
- **Infrastructure:** AWS CLI, systemd, cron, bash scripting
- **Cost:** ~$20/month (EC2 + EBS + S3 + Elastic IP)

## How to Use This Course

### SAA-C03 Exam Coverage

This course covers all four SAA-C03 exam domains:

| Domain | Weight | Modules |
|--------|--------|---------|
| Design Secure Architectures | 30% | 07, 15 |
| Design Resilient Architectures | 26% | 04, 09, 11, 13 |
| Design High-Performing Architectures | 24% | 09, 10, 12, 14 |
| Design Cost-Optimized Architectures | 20% | All modules |

Each Part 2 module includes an **Exam Lens** section with SAA-style scenario questions, "know the difference" comparisons, and cost traps.

## How to Use This Course

Each module follows a consistent structure:

1. **The Problem** — A real pain point from Haven (or a "what if" scenario)
2. **The Concept** — What the AWS service is and why it exists
3. **The Build** — Step-by-step commands with annotations
4. **The Gotcha** — What went wrong and how it was fixed
5. **The Result** — Proof it works with verification commands
6. **Key Takeaways** — 3-5 bullets summarizing what was learned

---

*Built by Brandon Derricott as part of the Haven crypto intelligence project. Deployed March 2026.*
