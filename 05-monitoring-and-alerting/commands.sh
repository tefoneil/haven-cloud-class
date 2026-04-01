#!/bin/bash
# =============================================================================
# Module 05: Monitoring & Alerting — All AWS CLI Commands
# =============================================================================
#
# This file contains every command used to set up CloudWatch monitoring and
# SNS alerting for the Haven daemon. Commands are annotated and ordered
# sequentially — run them top to bottom.
#
# Prerequisites:
#   - AWS CLI configured (Module 01)
#   - EC2 instance running with IAM role (Module 04)
#   - haven-daemon systemd service running (Module 03)
#   - heartbeat.sh script deployed (see this module's heartbeat.sh)
#
# =============================================================================


# =============================================================================
# STEP 1: Create SNS Topic
# =============================================================================
# SNS (Simple Notification Service) is how CloudWatch delivers alerts.
# A "topic" is a named channel that subscribers listen to.

aws sns create-topic \
    --name haven-alerts \
    --region us-east-1
# Returns: arn:aws:sns:us-east-1:484821991157:haven-alerts
# Save this ARN — you'll need it for the alarm and subscription commands.


# =============================================================================
# STEP 2: Subscribe Email to the Topic
# =============================================================================
# SNS supports multiple protocols: email, SMS, HTTPS, Lambda, SQS.
# Email is free and works immediately after confirmation.

aws sns subscribe \
    --topic-arn arn:aws:sns:us-east-1:484821991157:haven-alerts \
    --protocol email \
    --notification-endpoint tefoneil@gmail.com \
    --region us-east-1

# IMPORTANT: Check your email (including spam folder) and click the
# "Confirm subscription" link. SNS will NOT deliver notifications until
# the subscription is confirmed.


# =============================================================================
# STEP 3: Verify Subscription Status
# =============================================================================
# Confirm the subscription is active (not "PendingConfirmation").

aws sns list-subscriptions-by-topic \
    --topic-arn arn:aws:sns:us-east-1:484821991157:haven-alerts \
    --region us-east-1

# Look for:
#   "SubscriptionArn": "arn:aws:sns:us-east-1:484821991157:haven-alerts:abc123..."
# If it says "PendingConfirmation", you haven't clicked the email link yet.


# =============================================================================
# STEP 4: Deploy Heartbeat Script + Cron
# =============================================================================
# Copy heartbeat.sh to the EC2 instance and set up cron.
# (Run these on the EC2 instance, not locally.)

# On EC2:
# mkdir -p /home/ubuntu/scripts /home/ubuntu/logs
# cp heartbeat.sh /home/ubuntu/scripts/heartbeat.sh
# chmod +x /home/ubuntu/scripts/heartbeat.sh
#
# crontab -e
# Add: * * * * * /home/ubuntu/scripts/heartbeat.sh >> /home/ubuntu/logs/heartbeat.log 2>&1


# =============================================================================
# STEP 5: Verify Metrics Are Arriving in CloudWatch
# =============================================================================
# Wait 2-3 minutes after starting the cron job, then query CloudWatch.

aws cloudwatch get-metric-statistics \
    --namespace "Haven/Daemon" \
    --metric-name "DaemonRunning" \
    --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period 60 \
    --statistics Average \
    --dimensions Name=Service,Value=haven-daemon \
    --region us-east-1

# Expected: Datapoints with Average=1.0 for each minute.
# If empty, check: Is cron running? Does the IAM role have cloudwatch:PutMetricData?

# macOS note: If testing from Mac, date -d is not available.
# Use: date -u -v-5M +%Y-%m-%dT%H:%M:%S


# =============================================================================
# STEP 6: Create CloudWatch Alarm
# =============================================================================
# This alarm watches the DaemonRunning metric and sends an email via SNS
# when the daemon has been down for 2 consecutive minutes.

aws cloudwatch put-metric-alarm \
    --alarm-name "haven-daemon-down" \
    --alarm-description "Haven daemon is not running - DaemonRunning < 1 for 2+ consecutive minutes" \
    --namespace "Haven/Daemon" \
    --metric-name "DaemonRunning" \
    --dimensions Name=Service,Value=haven-daemon \
    --statistic Average \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 1 \
    --comparison-operator LessThanThreshold \
    --treat-missing-data breaching \
    --alarm-actions arn:aws:sns:us-east-1:484821991157:haven-alerts \
    --ok-actions arn:aws:sns:us-east-1:484821991157:haven-alerts \
    --region us-east-1

# Parameters explained:
#   --period 60              Each evaluation window is 60 seconds
#   --evaluation-periods 2   Need 2 consecutive failures to trigger
#   --threshold 1            DaemonRunning must be >= 1 to be healthy
#   --treat-missing-data breaching   No heartbeat data = assume daemon is down
#   --alarm-actions          Send to SNS when alarm fires (ALARM state)
#   --ok-actions             Send to SNS when alarm clears (OK state)


# =============================================================================
# STEP 7: Verify Alarm Configuration
# =============================================================================

aws cloudwatch describe-alarms \
    --alarm-names "haven-daemon-down" \
    --region us-east-1

# Key fields to verify:
#   StateValue: OK (if daemon is running)
#   ActionsEnabled: true
#   TreatMissingData: breaching
#   AlarmActions: [arn of SNS topic]
#   OKActions: [arn of SNS topic]


# =============================================================================
# STEP 8: Test the Full Alert Loop
# =============================================================================
# This is the most important step. Stop the daemon, wait for the alarm,
# verify the email arrives, then restart.

# On EC2: Stop the daemon
# sudo systemctl stop haven-daemon

# Watch alarm state transition (takes ~2 minutes)
watch -n 30 "aws cloudwatch describe-alarms \
    --alarm-names haven-daemon-down \
    --query 'MetricAlarms[0].StateValue' \
    --output text \
    --region us-east-1"

# Expected: OK → INSUFFICIENT_DATA → ALARM
# Check email: you should receive "ALARM: haven-daemon-down"

# On EC2: Restart the daemon
# sudo systemctl start haven-daemon

# Wait ~2 minutes — alarm should return to OK
# Check email: you should receive "OK: haven-daemon-down"


# =============================================================================
# USEFUL COMMANDS (Day-to-Day Operations)
# =============================================================================

# Check current alarm state
aws cloudwatch describe-alarms \
    --alarm-names "haven-daemon-down" \
    --query 'MetricAlarms[0].[StateValue,ActionsEnabled]' \
    --output text \
    --region us-east-1

# Enable alarm actions (for cutover day)
aws cloudwatch enable-alarm-actions \
    --alarm-names haven-daemon-down \
    --region us-east-1

# Disable alarm actions (for maintenance windows)
aws cloudwatch disable-alarm-actions \
    --alarm-names haven-daemon-down \
    --region us-east-1

# View alarm history (state transitions)
aws cloudwatch describe-alarm-history \
    --alarm-name "haven-daemon-down" \
    --history-item-type StateUpdate \
    --region us-east-1

# Send a test notification via SNS (bypasses CloudWatch)
aws sns publish \
    --topic-arn arn:aws:sns:us-east-1:484821991157:haven-alerts \
    --subject "TEST: Haven Alert" \
    --message "This is a test notification from the Haven monitoring system." \
    --region us-east-1

# View recent heartbeat metrics (last hour)
aws cloudwatch get-metric-statistics \
    --namespace "Haven/Daemon" \
    --metric-name "DaemonRunning" \
    --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period 60 \
    --statistics Average \
    --dimensions Name=Service,Value=haven-daemon \
    --region us-east-1
