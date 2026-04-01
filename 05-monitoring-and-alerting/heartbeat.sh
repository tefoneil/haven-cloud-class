#!/bin/bash
# =============================================================================
# Haven Daemon Heartbeat — Push health metric to CloudWatch
# =============================================================================
#
# Purpose:
#   Checks if the haven-daemon systemd service is running and pushes a
#   binary metric (1 = healthy, 0 = down) to CloudWatch every minute.
#
# How it works:
#   1. `systemctl is-active` checks the service state
#   2. `aws cloudwatch put-metric-data` pushes the result
#   3. A CloudWatch alarm watches for 2 consecutive 0s (or missing data)
#   4. On alarm, SNS sends an email notification
#
# Why a script + cron instead of the CloudWatch Agent?
#   The CloudWatch Agent is a 200MB daemon designed for collecting system
#   metrics (CPU, memory, disk) and log files. We need one binary metric.
#   A 10-line bash script is simpler, lighter, and easier to debug than
#   installing, configuring, and maintaining a full monitoring agent.
#
# What happens if this script stops running?
#   CloudWatch receives no data. The alarm is configured with
#   treat-missing-data=breaching, so "no data" triggers the alarm.
#   This covers the case where the EC2 instance itself is unreachable.
#
# Cron setup (runs every minute):
#   * * * * * /home/ubuntu/scripts/heartbeat.sh >> /home/ubuntu/logs/heartbeat.log 2>&1
#
# IAM Requirements:
#   EC2 instance role needs cloudwatch:PutMetricData permission.
#   This is included in the haven-ec2-role policy.
#
# =============================================================================

# CloudWatch metric configuration
NAMESPACE="Haven/Daemon"
METRIC_NAME="DaemonRunning"
REGION="us-east-1"

# ---------------------------------------------------------------------------
# Check daemon status
# ---------------------------------------------------------------------------
# systemctl is-active returns:
#   "active"       → service is running normally
#   "inactive"     → service is stopped
#   "failed"       → service crashed and was not restarted
#   "activating"   → service is starting up
#
# The --quiet flag suppresses output and sets the exit code:
#   0 = active
#   non-zero = anything else
#
# We only count "active" as healthy. Even "activating" gets a 0 because
# the daemon is not yet processing data.

if systemctl is-active --quiet haven-daemon; then
    VALUE=1
else
    VALUE=0
fi

# ---------------------------------------------------------------------------
# Push metric to CloudWatch
# ---------------------------------------------------------------------------
# put-metric-data sends a single data point to CloudWatch.
#
# --namespace: Groups related metrics. "Haven/Daemon" keeps our custom
#   metrics separate from AWS's built-in metrics (AWS/EC2, AWS/S3, etc.)
#
# --dimensions: Key-value tags for the metric. Allows filtering in the
#   CloudWatch console. If we later add a second service (e.g., a web
#   dashboard), we can use the same metric name with a different dimension.
#
# --unit "None": This metric is a boolean flag (1 or 0), not a count,
#   percentage, or rate. "None" is the correct unit for dimensionless values.
#
# Credentials come from the EC2 instance profile automatically — no access
# keys are stored on disk or passed as environment variables.

aws cloudwatch put-metric-data \
    --namespace "$NAMESPACE" \
    --metric-name "$METRIC_NAME" \
    --value "$VALUE" \
    --unit "None" \
    --dimensions Name=Service,Value=haven-daemon \
    --region "$REGION"
