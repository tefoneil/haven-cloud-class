# Module 04: Storage & Backups

> Maps to: AWS-4 (VID-137) | AWS Services: S3, IAM Roles, Instance Profiles

---

## The Problem

Haven's SQLite database is 574MB. It contains:

- **228,000 Telegram messages** from 47 crypto channels, collected over months
- **36,000 wallet signals** from on-chain tracking
- **400+ paper trades** across four lanes (A, M, S, EQ) — each one a data point toward proving or disproving a trading hypothesis
- **70 tables** of intelligence data — evidence packs, convergence records, outcome tracking, exit history

This data is irreplaceable. It cannot be re-downloaded. Telegram message history is ephemeral — channels delete messages, edit calls, change names. Wallet signals are timestamped observations of on-chain activity. Paper trade outcomes are the empirical record of months of strategy development.

We already lost data once. On the local MacBook, a SQLite corruption event (orphaned index from a dropped table) cascaded into a `malformed database schema` error that blocked ALL queries. The recovery involved `PRAGMA writable_schema` surgery, which fixed the immediate problem but exposed deeper corruption. We ended up restoring from a manual backup that was 3 days old. Three days of data, gone.

Now the database lives on a single EBS volume attached to a single EC2 instance. EBS volumes are durable (replicated within the AZ), but they are not immune to:
- Accidental deletion (`rm -rf` or `terraform destroy`)
- Application-level corruption (bad migration, concurrent writes)
- AZ outage (rare, but we are single-AZ)
- Human error (wrong instance terminated, volume detached)

We needed automated, off-instance backups that we never have to think about.

---

## The Concept

### S3: Unlimited Cloud Storage

Amazon S3 (Simple Storage Service) is object storage. You create a **bucket** (a named container), and you put **objects** (files) in it. Each object is identified by a **key** (its path within the bucket).

```
haven-backups-484821991157/          ← bucket
  └── haven-db/                      ← prefix (like a folder)
      ├── haven-2026-03-15-0600.db   ← object (the backup file)
      ├── haven-2026-03-15-1200.db
      ├── haven-2026-03-15-1800.db
      └── haven-2026-03-16-0000.db
```

Key S3 features we use:
- **Versioning**: Keeps previous versions of overwritten objects. Safety net for accidental overwrites.
- **Lifecycle policies**: Automatically delete objects older than N days. Prevents unbounded storage costs.
- **Durability**: 99.999999999% (eleven 9s). Your file is replicated across multiple facilities within the region.

### IAM Roles vs. Access Keys

There are two ways to give an EC2 instance permission to write to S3:

**Option A: Access keys on the instance** (bad)
```bash
# Someone puts these in ~/.aws/credentials or an .env file
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=wJal...
```

If the instance is compromised, the attacker has permanent AWS credentials. They can do whatever those keys allow — from any machine, forever, until you revoke them.

**Option B: IAM Roles + Instance Profiles** (correct)
```
EC2 Instance
    │
    ├── Instance Profile (container)
    │       │
    │       └── IAM Role (identity)
    │               │
    │               └── IAM Policy (permissions)
    │                       │
    │                       └── "You can PutObject to this one S3 bucket"
    │
    └── AWS SDK automatically gets temporary credentials
        (rotated every few hours, no keys on disk)
```

The instance assumes a **role**. The role has a **policy** defining exactly what it can do. The AWS SDK on the instance automatically retrieves temporary credentials from the instance metadata service. No keys are stored on disk. Credentials rotate automatically.

This is how AWS intends you to do it. Access keys on instances are a code smell.

### WAL-Safe SQLite Backups

Haven's SQLite database runs in WAL (Write-Ahead Logging) mode. This is critical for performance — WAL allows concurrent readers while a writer is active. But it means the database is actually three files:

```
data/haven.db          ← main database file
data/haven.db-wal      ← write-ahead log (uncommitted writes)
data/haven.db-shm      ← shared memory index for WAL
```

**You cannot safely copy a WAL-mode database with `cp`.** If you copy `haven.db` while the WAL file has uncommitted writes, the copy is missing those writes. Worse, if you copy the WAL file separately, the timestamps may not match, and the copy could be corrupted.

The correct method is SQLite's built-in `.backup` command:

```bash
sqlite3 /home/ubuntu/haven/data/haven.db ".backup /tmp/haven-backup.db"
```

This creates a consistent, self-contained snapshot. It handles WAL checkpointing internally. The resulting file is a complete database with no external dependencies.

---

## The Build

### Step 1: Create the S3 bucket

```bash
# Create a versioned bucket in us-east-1
# The account ID suffix ensures global uniqueness
aws s3api create-bucket \
  --bucket haven-backups-484821991157 \
  --region us-east-1

# Enable versioning — keeps previous versions of overwritten files
aws s3api put-bucket-versioning \
  --bucket haven-backups-484821991157 \
  --versioning-configuration Status=Enabled
```

### Step 2: Add a lifecycle policy

Without a lifecycle policy, backups accumulate forever. At 574MB every 6 hours, that is 2.3GB/day or ~70GB/month. S3 Standard costs $0.023/GB/month, so this would reach $1.60/month after one month, $19/month after a year. Not catastrophic, but wasteful.

A 90-day lifecycle keeps 3 months of history and auto-deletes older backups:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket haven-backups-484821991157 \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "delete-old-backups",
        "Status": "Enabled",
        "Filter": {
          "Prefix": "haven-db/"
        },
        "Expiration": {
          "Days": 90
        },
        "NoncurrentVersionExpiration": {
          "NoncurrentDays": 30
        }
      }
    ]
  }'
```

### Step 3: Create the IAM policy (least privilege)

The backup script only needs three S3 permissions on one specific bucket. Nothing else.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "HavenBackupS3Access",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::haven-backups-484821991157",
        "arn:aws:s3:::haven-backups-484821991157/*"
      ]
    }
  ]
}
```

Why two resources? `s3:ListBucket` operates on the bucket itself (no `/*`). `s3:PutObject` and `s3:GetObject` operate on objects within the bucket (`/*`). This is a common IAM gotcha — bucket-level and object-level actions need separate resource ARNs.

```bash
# Create the policy
aws iam create-policy \
  --policy-name haven-backup-s3 \
  --policy-document file://iam-policy.json
```

### Step 4: Create the IAM Role and Instance Profile

```bash
# Create the role with a trust policy allowing EC2 to assume it
aws iam create-role \
  --role-name haven-ec2-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# Attach our least-privilege backup policy to the role
aws iam attach-role-policy \
  --role-name haven-ec2-role \
  --policy-arn arn:aws:iam::484821991157:policy/haven-backup-s3

# Create an Instance Profile (the "container" that holds the role)
aws iam create-instance-profile \
  --instance-profile-name haven-ec2-profile

# Put the role into the profile
aws iam add-role-to-instance-profile \
  --instance-profile-name haven-ec2-profile \
  --role-name haven-ec2-role

# Associate the profile with our EC2 instance
aws ec2 associate-iam-instance-profile \
  --instance-id i-0901f92161a092f2c \
  --iam-instance-profile Name=haven-ec2-profile
```

### Step 5: Write the backup script

```bash
sudo nano /home/ubuntu/scripts/backup-haven-db.sh
sudo chmod +x /home/ubuntu/scripts/backup-haven-db.sh
```

The full script (also available as `backup.sh` in this module):

```bash
#!/bin/bash
# =============================================================================
# Haven Database Backup — WAL-safe SQLite → S3
# =============================================================================
# Runs every 6 hours via cron. Creates a consistent SQLite snapshot using
# the .backup command (not cp), then uploads to S3 with a timestamped key.
#
# Requirements:
#   - sqlite3 CLI installed
#   - aws CLI installed
#   - EC2 instance has IAM role with s3:PutObject permission
# =============================================================================

set -euo pipefail
# -e: exit on any error
# -u: treat unset variables as errors
# -o pipefail: catch errors in piped commands

DB_PATH="/home/ubuntu/haven/data/haven.db"
BUCKET="haven-backups-484821991157"
TIMESTAMP=$(date -u +"%Y-%m-%d-%H%M")
BACKUP_FILE="/tmp/haven-backup-${TIMESTAMP}.db"
S3_KEY="haven-db/haven-${TIMESTAMP}.db"

echo "[$(date -u)] Starting backup..."

# Step 1: Create WAL-safe snapshot
# sqlite3 .backup handles WAL checkpointing internally.
# The output is a single, self-contained database file.
# DO NOT use 'cp haven.db' — it misses WAL contents and can corrupt.
sqlite3 "$DB_PATH" ".backup $BACKUP_FILE"

# Step 2: Verify the backup is valid
# Run an integrity check on the backup file, not the live DB.
# This catches corruption before we waste bandwidth uploading a bad file.
INTEGRITY=$(sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;")
if [ "$INTEGRITY" != "ok" ]; then
    echo "[$(date -u)] ERROR: Backup integrity check FAILED: $INTEGRITY"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# Step 3: Upload to S3
# No --acl flag needed — bucket default ACL is private.
# aws CLI automatically uses the instance profile credentials (no keys needed).
aws s3 cp "$BACKUP_FILE" "s3://${BUCKET}/${S3_KEY}" --region us-east-1

# Step 4: Clean up local temp file
rm -f "$BACKUP_FILE"

# Step 5: Report size for monitoring
SIZE=$(aws s3api head-object \
  --bucket "$BUCKET" \
  --key "$S3_KEY" \
  --query 'ContentLength' \
  --output text \
  --region us-east-1)
SIZE_MB=$((SIZE / 1048576))

echo "[$(date -u)] Backup complete: s3://${BUCKET}/${S3_KEY} (${SIZE_MB}MB)"
```

### Step 6: Set up cron

```bash
# Edit cron for the ubuntu user
crontab -e

# Add this line — runs at 00:00, 06:00, 12:00, 18:00 UTC
0 */6 * * * /home/ubuntu/scripts/backup-haven-db.sh >> /home/ubuntu/logs/backup.log 2>&1
```

Why every 6 hours? It is a balance:
- **Every hour** = 574MB x 24 = 13.8GB/day in S3 transfer and storage. Overkill.
- **Every 24 hours** = up to 24 hours of data loss on corruption. Too much.
- **Every 6 hours** = max 6 hours of data loss, ~2.3GB/day in S3. Reasonable for a 574MB database.

### Step 7: Test the backup and restore process

```bash
# Run the backup manually
/home/ubuntu/scripts/backup-haven-db.sh

# Verify it is in S3
aws s3 ls s3://haven-backups-484821991157/haven-db/ --region us-east-1

# Test a restore (to /tmp, not over the live DB)
aws s3 cp s3://haven-backups-484821991157/haven-db/haven-2026-03-15-1800.db /tmp/haven-restore-test.db --region us-east-1

# Verify the restored file
sqlite3 /tmp/haven-restore-test.db "PRAGMA integrity_check;"
# ok

sqlite3 /tmp/haven-restore-test.db "SELECT COUNT(*) FROM messages;"
# 228431

# Clean up
rm /tmp/haven-restore-test.db
```

### Restore procedure (when you actually need it)

```bash
# 1. Stop the daemon
sudo systemctl stop haven-daemon

# 2. Back up the current (possibly corrupted) DB
mv /home/ubuntu/haven/data/haven.db /home/ubuntu/haven/data/haven.db.corrupted

# 3. Download the latest backup from S3
aws s3 cp s3://haven-backups-484821991157/haven-db/haven-2026-03-15-1800.db \
  /home/ubuntu/haven/data/haven.db --region us-east-1

# 4. Verify integrity
sqlite3 /home/ubuntu/haven/data/haven.db "PRAGMA integrity_check;"

# 5. Restart the daemon
sudo systemctl start haven-daemon

# 6. Verify daemon is healthy
sudo journalctl -u haven-daemon -n 20
```

---

## The Gotcha

### Gotcha 1: IAM credential propagation delay

After attaching the instance profile, the first `aws s3 cp` command failed with:

```
Unable to locate credentials. You can configure credentials by running "aws configure".
```

The instance profile was associated, the role had the policy attached, but the EC2 metadata service had not yet picked up the new credentials. IAM changes can take 10-30 seconds to propagate.

Waiting 30 seconds and retrying worked. In automation, this means you should not associate an instance profile and immediately run a command that depends on it — add a sleep or a retry loop.

### Gotcha 2: `cp` vs `.backup` for SQLite

This is worth emphasizing because it is a silent data loss vector.

Haven's database runs in WAL mode. At any given moment, the actual state of the database is split across three files:

```
haven.db       ← committed pages
haven.db-wal   ← uncommitted (but durable) writes
haven.db-shm   ← shared memory for WAL coordination
```

If you run `cp haven.db /tmp/backup.db` while the daemon is writing:
- The copy has committed data only — WAL writes are missing
- If the daemon was mid-transaction, the copy may have partial pages
- The copy might appear to pass `PRAGMA integrity_check` but have stale data
- Or it might just be corrupt

`sqlite3 haven.db ".backup /tmp/backup.db"` does a proper page-level copy with WAL checkpointing. The output is always a consistent, self-contained database.

We learned this lesson the hard way on the MacBook — a `cp`-based backup was missing 4 hours of messages. The backup "worked" but the data was stale. With `.backup`, this cannot happen.

---

## The Result

Automated, WAL-safe backups running every 6 hours with zero manual intervention:

```bash
# Verify backups are accumulating
$ aws s3 ls s3://haven-backups-484821991157/haven-db/ --region us-east-1
2026-03-15 18:00:05  601882624 haven-2026-03-15-1800.db
2026-03-16 00:00:04  602015744 haven-2026-03-16-0000.db
2026-03-16 06:00:05  602148864 haven-2026-03-16-0600.db
2026-03-16 12:00:04  602281984 haven-2026-03-16-1200.db

# Verify the instance has no access keys on disk
$ cat ~/.aws/credentials
# File does not exist — credentials come from the instance profile

# Verify IAM role is active
$ aws sts get-caller-identity
{
    "UserId": "AROA...:i-0901f92161a092f2c",
    "Account": "484821991157",
    "Arn": "arn:aws:sts::484821991157:assumed-role/haven-ec2-role/i-0901f92161a092f2c"
}

# Restore test: download + integrity check
$ aws s3 cp s3://haven-backups-484821991157/haven-db/haven-2026-03-16-1200.db /tmp/test.db --region us-east-1
$ sqlite3 /tmp/test.db "PRAGMA integrity_check;"
ok
```

574MB of irreplaceable data, backed up four times a day, automatically deleted after 90 days, with zero credentials on disk.

---

## Key Takeaways

- **IAM Roles are always better than access keys for EC2.** Roles provide temporary, auto-rotating credentials via the instance metadata service. No keys on disk means no keys to steal if the instance is compromised.

- **Least-privilege policies scope to specific resources.** Our backup policy allows `PutObject`, `GetObject`, and `ListBucket` on one bucket. Nothing else. If the role is compromised, the attacker can read and write Haven backups — they cannot access any other S3 bucket, launch instances, or escalate privileges.

- **SQLite requires `.backup` for safe copies in WAL mode.** Never use `cp`, `rsync`, or `scp` on a live WAL-mode database. The `.backup` command is the only method that guarantees a consistent snapshot while the database is being written to.

- **Lifecycle policies prevent unbounded storage costs.** Without a policy, backups accumulate forever. At 574MB every 6 hours, you would have 207GB after a year. A 90-day lifecycle keeps the last ~360 backups (~207GB peak) and automatically prunes older ones.

- **Test your restore process, not just your backup.** A backup you have never restored is a backup you cannot trust. Download a backup, verify its integrity, query it, and confirm the data is complete. Do this before you need it in an emergency.

---

## Files in This Module

| File | Description |
|------|-------------|
| `README.md` | This document |
| `backup.sh` | Annotated backup script — WAL-safe SQLite snapshot to S3 |
| `iam-policy.json` | Least-privilege IAM policy for S3 backup access |

---

*Next module: [05 - Monitoring & Alerting](../05-monitoring-and-alerting/) — CloudWatch alarms and SNS notifications for daemon health.*
