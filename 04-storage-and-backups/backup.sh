#!/bin/bash
# =============================================================================
# Haven Database Backup — WAL-safe SQLite → S3
# =============================================================================
#
# Purpose:
#   Creates a consistent snapshot of Haven's SQLite database and uploads it
#   to S3 with a timestamped filename. Runs every 6 hours via cron.
#
# Why not just `cp haven.db`?
#   Haven uses SQLite in WAL (Write-Ahead Logging) mode. The database state
#   is split across three files: haven.db, haven.db-wal, haven.db-shm.
#   Copying haven.db alone misses uncommitted WAL writes and can produce a
#   corrupted or stale backup. sqlite3's .backup command handles WAL
#   checkpointing internally, producing a single self-contained file.
#
# Cron setup (runs at 00:00, 06:00, 12:00, 18:00 UTC):
#   0 */6 * * * /home/ubuntu/scripts/backup-haven-db.sh >> /home/ubuntu/logs/backup.log 2>&1
#
# IAM Requirements:
#   EC2 instance must have an IAM role with s3:PutObject permission on the
#   target bucket. No access keys on disk — credentials come from the
#   instance metadata service automatically.
#
# =============================================================================

# Exit immediately on any error. Treat unset variables as errors.
# Catch errors in piped commands (not just the last command in a pipe).
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Path to the live Haven database
DB_PATH="/home/ubuntu/haven/data/haven.db"

# S3 bucket name (created with versioning enabled, 90-day lifecycle policy)
BUCKET="haven-backups-484821991157"

# Timestamp for the backup filename (UTC, format: 2026-03-15-1800)
TIMESTAMP=$(date -u +"%Y-%m-%d-%H%M")

# Local temp file for the backup (deleted after upload)
BACKUP_FILE="/tmp/haven-backup-${TIMESTAMP}.db"

# S3 object key (path within the bucket)
S3_KEY="haven-db/haven-${TIMESTAMP}.db"

# ---------------------------------------------------------------------------
# Step 1: Create WAL-safe snapshot
# ---------------------------------------------------------------------------
# sqlite3's .backup command:
#   - Acquires a shared lock on the source database
#   - Copies all pages (including WAL content) to the destination
#   - Produces a single, self-contained database file
#   - Does NOT interfere with the running daemon (shared lock, not exclusive)
#
# The daemon continues processing while the backup runs. This is safe because
# .backup uses SQLite's built-in page-level copy mechanism.

echo "[$(date -u)] Starting backup of ${DB_PATH}..."
sqlite3 "$DB_PATH" ".backup $BACKUP_FILE"
echo "[$(date -u)] Snapshot created: ${BACKUP_FILE}"

# ---------------------------------------------------------------------------
# Step 2: Verify backup integrity
# ---------------------------------------------------------------------------
# Run PRAGMA integrity_check on the BACKUP file, not the live database.
# This catches corruption before we upload. If the backup is bad, we fail
# loudly rather than silently storing a corrupt file in S3.
#
# integrity_check returns "ok" on success or a list of errors on failure.

INTEGRITY=$(sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;")
if [ "$INTEGRITY" != "ok" ]; then
    echo "[$(date -u)] ERROR: Backup integrity check FAILED"
    echo "[$(date -u)] Details: $INTEGRITY"
    rm -f "$BACKUP_FILE"
    exit 1
fi
echo "[$(date -u)] Integrity check: PASS"

# ---------------------------------------------------------------------------
# Step 3: Upload to S3
# ---------------------------------------------------------------------------
# aws s3 cp uses the instance profile credentials automatically.
# No access keys, no .aws/credentials file, no environment variables.
# The EC2 metadata service provides temporary credentials from the IAM role.
#
# If this fails, check:
#   1. Is the instance profile attached? (aws sts get-caller-identity)
#   2. Does the role have s3:PutObject on this bucket?
#   3. Is the bucket name correct?

aws s3 cp "$BACKUP_FILE" "s3://${BUCKET}/${S3_KEY}" --region us-east-1
echo "[$(date -u)] Uploaded to s3://${BUCKET}/${S3_KEY}"

# ---------------------------------------------------------------------------
# Step 4: Clean up local temp file
# ---------------------------------------------------------------------------
# The backup is safely in S3 now. No need to keep it on the EBS volume.
# At 574MB per backup, leaving them around would fill the 30GB disk in ~50 runs.

rm -f "$BACKUP_FILE"

# ---------------------------------------------------------------------------
# Step 5: Report backup size (for monitoring / log review)
# ---------------------------------------------------------------------------
# Query S3 for the uploaded object's size. Useful for spotting anomalies:
#   - Sudden size drop might mean data loss
#   - Sudden size spike might mean a runaway table
#   - Haven's DB has been growing ~1-2MB/day (messages + signals)

SIZE=$(aws s3api head-object \
    --bucket "$BUCKET" \
    --key "$S3_KEY" \
    --query 'ContentLength' \
    --output text \
    --region us-east-1)
SIZE_MB=$((SIZE / 1048576))

echo "[$(date -u)] Backup complete: ${SIZE_MB}MB → s3://${BUCKET}/${S3_KEY}"
