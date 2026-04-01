# Haven Cloud Architecture — Study Guide

> Complete course summary organized by module. Use this for review before interviews or as a quick reference.

---

## Module 00: Why Cloud?

**Key insight:** Production workloads need production infrastructure. A $20/month EC2 instance is cheaper than one lost database.

- Local development machines are not servers — they sleep, restart, lose network
- Haven lost 19 paper trades and 18 days of data due to laptop-induced DB corruption
- Cloud migration cost: ~$20/month for EC2 + S3 + monitoring
- The decision: reliability > convenience

---

## Module 01: VPC & Compute

**Services:** VPC, EC2, Security Groups, Internet Gateway, Subnets

| Concept | Analogy |
|---------|---------|
| VPC | Your own private data center |
| Subnet | A room within the data center |
| Security Group | A firewall at each door |
| Internet Gateway | The front door to the internet |
| EC2 Instance | The actual computer |

**Key commands:**
- `aws ec2 create-vpc` → your isolated network
- `aws ec2 run-instances` → launch a server
- `aws ec2 authorize-security-group-ingress` → open a port

**Interview tip:** "A VPC provides network isolation. I used a single public subnet with a security group restricting SSH to my IP. For production, I'd add private subnets and a NAT gateway."

---

## Module 02: Application Deployment

**Pattern:** Clone via deploy key, SCP secrets, install dependencies, verify manually.

- Deploy keys: read-only, scoped to one repo, safer than PATs
- SCP for secrets (.env), git for code — never mix them
- Poetry creates virtualenvs in a different path on Ubuntu vs Mac
- Always verify the app runs manually before automating

**Interview tip:** "I use a deploy key for read-only repo access and SCP for secrets. The app is verified manually before adding systemd automation."

---

## Module 03: Process Management

**Service:** systemd

**Why not nohup?** Process dies on reboot. No auto-restart. No log management. No dependency ordering.

**Unit file essentials:**
```ini
[Service]
Type=simple
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1
TimeoutStopSec=30
```

**Key commands:**
- `systemctl enable` → start on boot
- `systemctl start/stop/restart` → control the service
- `journalctl -u haven-daemon -f` → tail logs

**Interview tip:** "systemd provides process supervision with auto-restart, boot persistence, and centralized logging via journald. I set TimeoutStopSec because my async Python daemon doesn't handle SIGTERM gracefully."

---

## Module 04: Storage & Backups

**Services:** S3, IAM Roles, Instance Profiles

**Critical pattern:** `sqlite3 $DB ".backup $DEST"` — NOT `cp`
- `cp` on a WAL-mode SQLite database can produce a corrupted copy
- `.backup` creates a consistent snapshot regardless of write activity

**IAM chain:** Policy → Role → Instance Profile → EC2
- Policy defines what you can do (S3 PutObject on specific bucket)
- Role assumes the policy
- Instance Profile attaches the role to EC2
- No access keys stored on the machine

**Interview tip:** "I use IAM Roles with Instance Profiles so EC2 can access S3 without storing credentials on disk. Backups use SQLite's .backup command for WAL-safe copies, automated via cron every 6 hours."

---

## Module 05: Monitoring & Alerting

**Services:** CloudWatch (metrics + alarms), SNS (notifications)

**Pattern:** Heartbeat script (cron, every 1 min) → pushes custom metric → CloudWatch alarm evaluates → SNS sends email if daemon is down for 2+ minutes.

**Key setting:** `treat-missing-data=breaching` — if the heartbeat stops sending data, the alarm assumes the worst and fires. This catches scenarios where the entire instance is down (no heartbeat script running to report 0).

**Interview tip:** "I implemented a custom heartbeat metric that reports daemon status every minute. CloudWatch alarms fire on two consecutive missing/zero readings, triggering email alerts via SNS."

---

## Module 06: Secrets Management

**Service:** SSM Parameter Store

**Pattern:** Startup wrapper
1. Shell script runs before the application
2. Fetches all `/haven/*` parameters from SSM with decryption
3. Exports as environment variables
4. Execs into the application process

**Why not .env files?**
- Plaintext on disk — anyone with SSH access can read them
- SSM encrypts at rest with KMS
- Central management — update a secret in one place
- Audit trail — CloudTrail logs who accessed what

**Interview tip:** "Secrets are stored in SSM Parameter Store as SecureStrings. A startup wrapper fetches and exports them at boot time, so no plaintext credentials exist on disk."

---

## Module 07: Security Hardening

**Principle:** Defense in depth — assume every layer will be breached.

**Layers implemented:**
1. **IAM least-privilege** — scoped policy replacing AdministratorAccess
2. **Security Group** — SSH restricted to one IP
3. **Key-only SSH** — password authentication disabled
4. **fail2ban** — auto-bans brute-force attempts
5. **SSM secrets** — no plaintext credentials on disk

**Gotcha pattern:** Least-privilege is iterative. You'll get AccessDenied errors and need to add permissions. That's normal. Keep Console AdminAccess as break-glass.

**Interview tip:** "I replaced AdminAccess with a scoped IAM policy covering only the services Haven uses. SSH is key-only with fail2ban. I discovered missing permissions iteratively — that's the expected workflow for least-privilege."

---

## Module 08: Operational Dashboards

**Service:** CloudWatch Dashboards

**6 widgets:**
1. Daemon Heartbeat (custom metric, 0/1 timeline)
2. EC2 CPU Utilization
3. Network In/Out
4. Disk Read/Write Ops
5. Alarm Status
6. Text reference panel (SSH command, log command, backup path)

**Design principle:** A dashboard should answer "is everything OK?" in under 5 seconds without SSH.

**Interview tip:** "I built a CloudWatch dashboard with custom metrics, standard EC2 metrics, alarm status, and a reference panel. It gives me single-pane-of-glass visibility without needing to SSH in."

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│ AWS (us-east-1)                             │
│                                             │
│  VPC (10.0.0.0/16)                         │
│  ├── Subnet (10.0.1.0/24)                  │
│  │   └── EC2 t3.small (Ubuntu 24.04)       │
│  │       ├── systemd → haven-daemon        │
│  │       ├── start-daemon.sh (SSM wrapper) │
│  │       ├── heartbeat.sh (CloudWatch)     │
│  │       ├── backup.sh (S3, every 6h)      │
│  │       └── fail2ban + key-only SSH       │
│  │                                         │
│  ├── Security Group (SSH from home IP)     │
│  └── Internet Gateway                      │
│                                             │
│  S3: haven-backups (versioned, 90d lifecycle)│
│  SSM: /haven/* (30 SecureStrings)           │
│  CloudWatch: Haven-Operations dashboard     │
│  SNS: haven-alerts → email                  │
│  IAM: haven-dev-scoped (least-privilege)    │
│  Elastic IP: 52.5.244.137                   │
│                                             │
│  Monthly cost: ~$20                         │
└─────────────────────────────────────────────┘
```

## Cost Breakdown

| Service | Monthly Cost |
|---------|-------------|
| EC2 t3.small (on-demand) | ~$15 |
| EBS 30GB gp3 | ~$2.40 |
| S3 backups | ~$0.50 |
| Elastic IP (attached) | $0 |
| CloudWatch (free tier) | $0 |
| SNS email | $0 |
| SSM Parameter Store | $0 |
| **Total** | **~$20** |
