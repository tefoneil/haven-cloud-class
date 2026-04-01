# Module 05: Monitoring & Alerting

> Maps to: AWS-5 (VID-138) | AWS Services: CloudWatch, SNS

---

## The Problem

Haven runs 24/7. It processes live market data, tracks open paper trades, monitors exit conditions, and sends Telegram alerts when signals fire. If the daemon goes down at 3 AM, the consequences are:

- **Missed signals**: Wallet convergence events, channel caller alerts, and new token launches go undetected.
- **Abandoned paper trades**: Open positions with active exit monitoring (trailing stops, take-profit levels) stop being watched. A trade that hit TP2 at +25% could dump to -20% before anyone notices.
- **Data gaps**: Every minute the daemon is down, messages from 47 Telegram channels are not being captured. Those messages cannot be recovered — most crypto channels do not preserve history.
- **Silent failure**: The daemon does not call your phone when it dies. It just stops. You discover the outage when you check your phone in the morning and realize there have been zero Telegram alerts for 8 hours.

We already had systemd with `Restart=always` (Module 03), so the daemon restarts automatically after crashes. But what about failures that systemd cannot fix?

- The daemon process is running but deadlocked (all async loops frozen, PID alive but doing nothing)
- The EC2 instance itself is unreachable (network issue, AZ problem)
- systemd restarted the daemon 5 times and gave up (`start-limit-hit`)
- Someone ran `systemctl stop` and forgot to start it again

We needed an external monitoring system that checks from outside the instance and sends a notification when things are wrong. Not "check it yourself" — push a notification to your phone.

---

## The Concept

### CloudWatch: AWS's Monitoring Service

CloudWatch collects **metrics** — time-series data points. AWS services automatically publish metrics (EC2 CPU usage, EBS disk I/O, S3 request counts), but you can also push **custom metrics** from your own scripts.

A metric has:
- **Namespace**: A grouping (e.g., `Haven/Daemon`)
- **MetricName**: What is being measured (e.g., `DaemonRunning`)
- **Value**: The data point (e.g., `1` or `0`)
- **Timestamp**: When the measurement was taken

### CloudWatch Alarms

An alarm watches a metric and changes state based on conditions:

```
           metric value
                │
     ┌──────────┼──────────────────────────────────────
     │          │
  1  │  ████████│████████████        ████████████████
     │          │            │      │
  0  │          │            ██████│█
     │          │            │      │
     └──────────┼────────────┼──────┼─────────────────
                │            │      │
                OK           │      OK
                             │
                          ALARM → SNS → Email
                    (2 consecutive periods < 1)
```

Key alarm concepts:
- **Threshold**: "DaemonRunning < 1" — any value below 1 means trouble
- **Evaluation periods**: "2 consecutive periods" — avoids alerting on momentary blips (systemd restart takes ~10 seconds)
- **treat-missing-data**: What to do when no data arrives. Options:
  - `missing` — do nothing (ignore gaps)
  - `breaching` — treat no data as a failure
  - `notBreaching` — treat no data as healthy
  - `ignore` — maintain current state

For a heartbeat, `breaching` is correct. If the heartbeat script stops sending data, that means either the script is broken or the instance is down. Both are problems.

### SNS: Simple Notification Service

SNS is a pub/sub messaging service. You create a **topic**, subscribe **endpoints** to it (email, SMS, HTTPS webhook, Lambda), and **publish** messages to it. All subscribers receive the message.

```
CloudWatch Alarm (ALARM state)
        │
        ▼
SNS Topic: haven-alerts
        │
        ├── Email: tefoneil@gmail.com
        ├── (Future) SMS: +1-xxx-xxx-xxxx
        └── (Future) Telegram webhook
```

For Haven, email is sufficient. It is free, requires no registration, and most people have email push notifications on their phone. SMS requires AWS account registration and costs $2/month for an origination number.

---

## The Build

### Step 1: Create the SNS topic

```bash
# Create the topic — returns an ARN (Amazon Resource Name)
aws sns create-topic --name haven-alerts --region us-east-1
# Output: arn:aws:sns:us-east-1:484821991157:haven-alerts
```

### Step 2: Subscribe your email

```bash
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:484821991157:haven-alerts \
  --protocol email \
  --notification-endpoint tefoneil@gmail.com \
  --region us-east-1
```

**Important:** This sends a confirmation email. You must click the "Confirm subscription" link in that email before SNS will deliver any notifications. Check your spam folder.

Verify the subscription is confirmed:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:484821991157:haven-alerts \
  --region us-east-1
```

Look for `"SubscriptionArn"` — if it says `"PendingConfirmation"`, you have not clicked the email link yet.

### Step 3: Write the heartbeat script

The heartbeat script runs on the EC2 instance every minute via cron. It checks if the daemon is running and pushes a `1` (healthy) or `0` (down) to CloudWatch.

```bash
sudo nano /home/ubuntu/scripts/heartbeat.sh
sudo chmod +x /home/ubuntu/scripts/heartbeat.sh
```

Full script (also available as `heartbeat.sh` in this module):

```bash
#!/bin/bash
# =============================================================================
# Haven Daemon Heartbeat — Push health metric to CloudWatch
# =============================================================================
# Checks systemctl is-active for the haven-daemon service.
# Pushes DaemonRunning=1 (healthy) or DaemonRunning=0 (down) to CloudWatch.
# Runs every minute via cron.
#
# If this script itself stops running (instance down, cron broken), CloudWatch
# receives no data. The alarm is configured with treat-missing-data=breaching,
# so "no data" is treated as "daemon is down." This is the correct behavior —
# if we can't even run the health check, something is seriously wrong.
# =============================================================================

NAMESPACE="Haven/Daemon"
METRIC_NAME="DaemonRunning"
REGION="us-east-1"

# systemctl is-active returns "active" if the service is running,
# or "inactive"/"failed"/"activating" otherwise.
# We only care about "active" — anything else means the daemon is not
# processing data.
if systemctl is-active --quiet haven-daemon; then
    VALUE=1
else
    VALUE=0
fi

# Push the metric to CloudWatch.
# --dimensions lets us tag the metric (useful if you later have multiple
# instances or services). For now, we tag with the service name.
aws cloudwatch put-metric-data \
    --namespace "$NAMESPACE" \
    --metric-name "$METRIC_NAME" \
    --value "$VALUE" \
    --unit "None" \
    --dimensions Name=Service,Value=haven-daemon \
    --region "$REGION"
```

### Step 4: Schedule the heartbeat via cron

```bash
crontab -e

# Add: run every minute, log output
* * * * * /home/ubuntu/scripts/heartbeat.sh >> /home/ubuntu/logs/heartbeat.log 2>&1
```

Every minute, CloudWatch receives a data point. This is the pulse that the alarm watches.

### Step 5: Verify metrics are arriving

Wait 2-3 minutes after setting up the cron job, then check:

```bash
# Query the last 5 minutes of DaemonRunning metrics
aws cloudwatch get-metric-statistics \
    --namespace "Haven/Daemon" \
    --metric-name "DaemonRunning" \
    --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period 60 \
    --statistics Average \
    --dimensions Name=Service,Value=haven-daemon \
    --region us-east-1
```

You should see data points with value `1.0` for each minute.

### Step 6: Create the CloudWatch alarm

```bash
aws cloudwatch put-metric-alarm \
    --alarm-name "haven-daemon-down" \
    --alarm-description "Haven daemon is not running — DaemonRunning metric is 0 or missing for 2+ minutes" \
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
```

Breaking this down:

| Parameter | Value | Why |
|-----------|-------|-----|
| `--period 60` | 1 minute | Matches our heartbeat frequency |
| `--evaluation-periods 2` | 2 consecutive | Avoids false alarms during systemd restart (~10s) |
| `--threshold 1` | Value must be >= 1 | 0 = down, 1 = healthy |
| `--comparison-operator LessThanThreshold` | Alert when < 1 | Fires when daemon is down |
| `--treat-missing-data breaching` | No data = assume down | If the heartbeat stops, the instance might be dead |
| `--alarm-actions` | SNS topic | Send email when alarm fires |
| `--ok-actions` | SNS topic | Send email when alarm clears (daemon is back) |

**Note on initial state:** We created this alarm with actions enabled during the build. In our actual migration, we created it with `--alarm-actions` omitted initially (effectively disabled) because we were not ready for cutover yet — the local MacBook daemon was still primary. On cutover day, we enabled the alarm actions:

```bash
aws cloudwatch enable-alarm-actions --alarm-names haven-daemon-down --region us-east-1
```

### Step 7: Test the full alert loop

This is the most important step. An untested alert is not an alert — it is a hope.

```bash
# Stop the daemon (this is on the EC2 instance)
sudo systemctl stop haven-daemon

# Watch the alarm state (takes ~2 minutes to trigger)
watch -n 30 "aws cloudwatch describe-alarms \
    --alarm-names haven-daemon-down \
    --query 'MetricAlarms[0].StateValue' \
    --output text \
    --region us-east-1"
```

Expected sequence:
1. **T+0:** Daemon stops. Next heartbeat pushes `DaemonRunning=0`.
2. **T+1 min:** First data point below threshold. Alarm evaluates but needs 2 consecutive periods.
3. **T+2 min:** Second data point below threshold. Alarm transitions to `ALARM` state.
4. **Email arrives:** Subject line: `ALARM: "haven-daemon-down" in US East (N. Virginia)`

Check your email. If it arrived, the monitoring pipeline works end-to-end.

Now restart the daemon:

```bash
sudo systemctl start haven-daemon

# Wait ~2 minutes — alarm should return to OK
# You'll get a second email: OK: "haven-daemon-down" in US East (N. Virginia)
```

The OK notification confirms the alarm clears properly. You get alerted when things break AND when they recover.

---

## The Gotcha

### Gotcha 1: SMS sandbox limitations

We tried to add SMS notifications alongside email. AWS returned:

```
An error occurred (AuthorizationError) when calling the Subscribe operation:
Could not subscribe to the topic. Reason: SMS sandbox.
```

New AWS accounts start in the **SMS sandbox**. You can only send SMS to verified phone numbers (up to 10), and you need to register an **origination number** ($2/month) before sending to any number.

For Haven, this was not worth the friction. Email push notifications on a phone achieve the same result — your phone buzzes when the daemon goes down. SMS was deferred.

**Lesson:** Do not assume all SNS protocols work out of the box. Email is immediately available after clicking the confirmation link. SMS, HTTPS, and Lambda endpoints have additional setup requirements.

### Gotcha 2: Alarm created in DISABLED state

During the migration, we built the monitoring infrastructure before we were ready to cut over from the local daemon. The alarm was created without `--alarm-actions` (no SNS topic attached), which meant it would transition to ALARM state but not send any notifications.

On cutover day, two weeks later, we almost forgot to enable it. The alarm was sitting in ALARM state (because the cloud daemon was not running yet) but nobody was being notified.

The cutover checklist (Module 03 references this) includes:

```bash
aws cloudwatch enable-alarm-actions --alarm-names haven-daemon-down --region us-east-1
```

**Lesson:** If you create monitoring infrastructure before go-live, put "enable alarm actions" on your cutover checklist. A disabled alarm is invisible.

### Gotcha 3: Heartbeat checks process, not function

The heartbeat script checks `systemctl is-active haven-daemon`. This confirms the process is running. It does not confirm the daemon is actually doing useful work.

Haven has 34 async loops. If 33 of them crash (due to `asyncio.gather` without `return_exceptions=True` — a bug we had in February), the process stays alive because the Telegram listener loop is still running. `systemctl is-active` reports "active." The heartbeat pushes `1`. The alarm stays in OK state. But 33 out of 34 data pipelines are dead.

For Haven, this is acceptable because:
1. We fixed the gather bug (`return_exceptions=True` on all loops)
2. The daemon logs crashed loops, and we check logs daily
3. A deeper health check (query the DB for recent activity) is a future enhancement

But it is worth understanding the limitation: **a heartbeat tells you the process exists, not that it is healthy.** For a production system, you would add application-level health checks — query the database for "last message received within 5 minutes" or "last exit check within 10 minutes."

---

## The Result

The monitoring pipeline is complete. Here is what happens when the daemon goes down:

```
T+0s     Daemon crashes (or is stopped)
           │
T+0s     systemd detects exit, schedules restart in 10s
           │
T+10s    systemd restarts daemon (Restart=always)
           │
           ├── If restart succeeds: daemon is back, next heartbeat pushes 1
           │   Alarm never fires. Self-healing worked.
           │
           └── If restart fails (5x → start-limit-hit):
               │
T+60s          Heartbeat pushes DaemonRunning=0 (first breach)
               │
T+120s         Heartbeat pushes DaemonRunning=0 (second consecutive breach)
               │
T+120s         CloudWatch alarm → ALARM state
               │
T+121s         SNS → Email notification
               │
               └── "ALARM: haven-daemon-down in US East (N. Virginia)"
                   → Your phone buzzes. You SSH in and investigate.
```

Worst case: **2 minutes from daemon death to email notification.**

Best case (transient crash): systemd restarts the daemon in 10 seconds, the alarm never fires, and you never even know it happened. You can see it later in `journalctl`:

```
Mar 16 03:14:22 systemd[1]: haven-daemon.service: Main process exited, code=killed, status=9/KILL
Mar 16 03:14:32 systemd[1]: haven-daemon.service: Scheduled restart job, restart counter is at 1.
Mar 16 03:14:33 systemd[1]: Started haven-daemon.service
```

Verify the alarm is live:

```bash
$ aws cloudwatch describe-alarms \
    --alarm-names haven-daemon-down \
    --query 'MetricAlarms[0].[StateValue,ActionsEnabled]' \
    --output text \
    --region us-east-1
OK    True
```

`OK` = daemon is running. `True` = alarm actions are enabled (will send email on state change).

---

## Key Takeaways

- **Custom metrics are simple.** One `aws cloudwatch put-metric-data` call per data point. No SDK, no agent, no setup beyond IAM permissions. A 10-line bash script replaces complex monitoring agents.

- **`treat-missing-data=breaching` is the right default for heartbeats.** If the heartbeat stops sending data, either the script is broken or the instance is unreachable. Both are emergencies. "No data = assume broken" is the safe assumption.

- **Test the full alert loop end-to-end before you need it.** Stop the daemon, wait for the email, start the daemon, wait for the OK email. If you skip this test, you will discover your monitoring is broken at 3 AM when you actually need it.

- **Email alerts are free and immediately available.** SMS requires AWS sandbox registration and costs $2/month per origination number. For most use cases, email push notifications on your phone are just as fast and cost nothing.

- **A heartbeat checks existence, not health.** `systemctl is-active` tells you the process is alive. It does not tell you the process is doing useful work. For deeper health monitoring, add application-level checks (e.g., "last database write within N minutes"). For Haven, process-level monitoring is sufficient because systemd + asyncio gather handle most failure modes.

- **Two evaluation periods prevent false alarms.** systemd restarts take ~10 seconds. If the alarm fired on a single missed heartbeat, every crash-and-recovery would produce a false alarm. Two consecutive breaches (2 minutes) gives systemd time to self-heal before escalating to a human.

---

## Files in This Module

| File | Description |
|------|-------------|
| `README.md` | This document |
| `heartbeat.sh` | Annotated heartbeat script — checks daemon status, pushes to CloudWatch |
| `commands.sh` | All AWS CLI commands for SNS, CloudWatch alarm creation, and testing |

---

*Next module: [06 - Secrets Management](../06-secrets-management/) — moving API keys from `.env` files to AWS Systems Manager Parameter Store.*
