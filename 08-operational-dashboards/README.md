# Module 08: Operational Dashboards

> **Maps to:** AWS-8 (VID-141) | **Services:** CloudWatch Dashboards
>
> **Time to complete:** ~20 minutes | **Prerequisites:** Module 05 (CloudWatch metrics and alarms)

---

## The Problem

Checking on Haven means opening a terminal and typing commands.

Is the daemon running? SSH in, run `sudo systemctl status haven-daemon`. How is CPU? SSH in, run `top`. Is the heartbeat alarm green? Run `aws cloudwatch describe-alarms`. When was the last backup? Run `aws s3 ls haven-backups-484821991157 --recursive | tail -5`. Are any loops crashing? Run `sudo journalctl -u haven-daemon -n 100 | grep ERROR`.

Each of these is a 20-second operation. Five checks is two minutes. And you have to remember to do them. At 3 AM when you wake up and wonder if the daemon is still processing Lane S launches, you are not going to SSH into a server. You are going to look at your phone, and if you can not get the answer in 5 seconds, you are either going back to sleep worried or spending 10 minutes debugging from bed.

The monitoring stack from Module 05 solves the "is it broken?" question -- the alarm fires and you get an email. But it does not answer "how is it doing?" There is a difference between "not dead" and "healthy." A daemon can be running with 95% CPU, no recent backups, and a flapping heartbeat. None of those trigger the alarm (which only fires on 3 consecutive missed heartbeats), but all of them are problems worth knowing about.

What we need is a single page that answers "is everything OK?" in under 5 seconds.

---

## The Concept

**CloudWatch Dashboards** are customizable monitoring pages in the AWS Console. Each dashboard contains widgets -- charts, numbers, text, alarm status indicators -- arranged on a grid. You open a URL, and you see your system's health at a glance.

### Widget types

| Widget | What It Shows | Use For |
|--------|---------------|---------|
| **Line chart** | Metric over time | CPU, network, heartbeat history |
| **Number** | Single current value | Current CPU %, alarm count |
| **Alarm status** | Green/yellow/red indicators | Is the daemon up? |
| **Text** | Markdown-formatted text | Reference info, commands, links |

### Pricing

The first 3 dashboards are free. Each additional dashboard is $3/month. Haven needs one dashboard. Free.

Each dashboard can have up to 500 widgets (we will use 6). Dashboards auto-refresh every 1, 5, or 10 minutes. Data retention follows the underlying metrics -- 15 months for standard resolution, 3 hours for 1-second resolution.

### The mental model

Think of the dashboard as the instrument panel on a car. You do not need it to drive -- the engine runs without the dashboard. But without it, you are flying blind. You do not know your speed, your fuel level, or your engine temperature until something physically breaks.

The dashboard does not fix problems. It makes problems visible before they become emergencies.

---

## The Build

### Step 1: Plan the layout

Before writing JSON, decide what you want to see. The dashboard should answer these questions:

1. **Is the daemon alive?** (heartbeat metric)
2. **Is the server healthy?** (CPU utilization)
3. **Is the network active?** (bytes in/out -- proves API calls are happening)
4. **Is the disk OK?** (read/write ops -- catches I/O storms from SQLite)
5. **Is the alarm green?** (single indicator -- the most important widget)
6. **How do I get in?** (SSH command, log command, backup path)

Six widgets, arranged in a 3x2 grid. Top row: heartbeat, CPU, network. Bottom row: disk, alarm, reference text.

### Step 2: Build the dashboard JSON

CloudWatch dashboards are defined as JSON documents. The `put-dashboard` API takes the dashboard name and a JSON body that describes all widgets, their positions, their data sources, and their formatting.

Here is the full dashboard definition:

```json
{
  "widgets": [
    {
      "type": "metric",
      "x": 0,
      "y": 0,
      "width": 8,
      "height": 6,
      "properties": {
        "title": "Daemon Heartbeat",
        "metrics": [
          [
            "Haven",
            "DaemonHeartbeat",
            {
              "stat": "Maximum",
              "period": 60,
              "color": "#2ca02c"
            }
          ]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "yAxis": {
          "left": {
            "min": 0,
            "max": 1.5,
            "label": "1 = alive"
          }
        },
        "period": 60,
        "annotations": {
          "horizontal": [
            {
              "label": "Healthy",
              "value": 1,
              "color": "#2ca02c"
            }
          ]
        }
      }
    },
    {
      "type": "metric",
      "x": 8,
      "y": 0,
      "width": 8,
      "height": 6,
      "properties": {
        "title": "EC2 CPU Utilization",
        "metrics": [
          [
            "AWS/EC2",
            "CPUUtilization",
            "InstanceId",
            "i-0901f92161a092f2c",
            {
              "stat": "Average",
              "period": 300,
              "color": "#1f77b4"
            }
          ]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "yAxis": {
          "left": {
            "min": 0,
            "max": 100,
            "label": "%"
          }
        },
        "period": 300,
        "annotations": {
          "horizontal": [
            {
              "label": "Warning",
              "value": 80,
              "color": "#ff7f0e"
            }
          ]
        }
      }
    },
    {
      "type": "metric",
      "x": 16,
      "y": 0,
      "width": 8,
      "height": 6,
      "properties": {
        "title": "Network In / Out",
        "metrics": [
          [
            "AWS/EC2",
            "NetworkIn",
            "InstanceId",
            "i-0901f92161a092f2c",
            {
              "stat": "Sum",
              "period": 300,
              "color": "#2ca02c",
              "label": "Bytes In"
            }
          ],
          [
            "AWS/EC2",
            "NetworkOut",
            "InstanceId",
            "i-0901f92161a092f2c",
            {
              "stat": "Sum",
              "period": 300,
              "color": "#d62728",
              "label": "Bytes Out"
            }
          ]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "period": 300
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 6,
      "width": 8,
      "height": 6,
      "properties": {
        "title": "Disk Operations",
        "metrics": [
          [
            "AWS/EC2",
            "DiskReadOps",
            "InstanceId",
            "i-0901f92161a092f2c",
            {
              "stat": "Sum",
              "period": 300,
              "color": "#1f77b4",
              "label": "Read Ops"
            }
          ],
          [
            "AWS/EC2",
            "DiskWriteOps",
            "InstanceId",
            "i-0901f92161a092f2c",
            {
              "stat": "Sum",
              "period": 300,
              "color": "#ff7f0e",
              "label": "Write Ops"
            }
          ]
        ],
        "view": "timeSeries",
        "region": "us-east-1",
        "period": 300
      }
    },
    {
      "type": "alarm",
      "x": 8,
      "y": 6,
      "width": 8,
      "height": 6,
      "properties": {
        "title": "Alarm Status",
        "alarms": [
          "arn:aws:cloudwatch:us-east-1:484821991157:alarm:haven-daemon-down"
        ],
        "sortBy": "stateUpdatedTimestamp",
        "states": [
          {
            "value": "ALARM",
            "label": "DAEMON DOWN"
          },
          {
            "value": "OK",
            "label": "Healthy"
          },
          {
            "value": "INSUFFICIENT_DATA",
            "label": "No data"
          }
        ]
      }
    },
    {
      "type": "text",
      "x": 16,
      "y": 6,
      "width": 8,
      "height": 6,
      "properties": {
        "markdown": "## Quick Reference\n\n**SSH:**\n```\nssh -i ~/.ssh/haven-key.pem ubuntu@52.5.244.137\n```\n\n**Logs:**\n```\nsudo journalctl -u haven-daemon -f\n```\n\n**Restart:**\n```\nsudo systemctl restart haven-daemon\n```\n\n**Backups:**\n```\naws s3 ls haven-backups-484821991157/\n```\n\n**Instance:** i-0901f92161a092f2c (t3.small)\n**Elastic IP:** 52.5.244.137\n**Region:** us-east-1"
      }
    }
  ]
}
```

### Step 3: Create the dashboard

Save the JSON above as `dashboard.json` and push it to CloudWatch:

```bash
aws cloudwatch put-dashboard \
  --dashboard-name "Haven-Operations" \
  --dashboard-body file://dashboard.json \
  --region us-east-1
```

If successful, the response will be:

```json
{
    "DashboardValidationMessages": []
}
```

An empty `DashboardValidationMessages` array means the dashboard was created without errors. If there are validation issues (bad metric names, invalid widget types), they will appear here.

### Step 4: Access the dashboard

The dashboard is now live in the AWS Console:

```
https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/Haven-Operations
```

Bookmark this URL. This is the single page you open to check on Haven.

### Step 5: Configure auto-refresh

In the Console, click the refresh icon in the top-right corner of the dashboard and select your preferred interval:

- **1 minute** for active monitoring (during deployments, after restarts)
- **5 minutes** for daily checks (the default)
- **10 minutes** for background tabs

The dashboard auto-refreshes in the browser. No manual action needed after the initial load.

### Step 6: Verify each widget

Walk through each widget and confirm it is showing data:

```bash
# 1. Heartbeat — should show 1.0 data points every minute
#    (from the cron job created in Module 05)
aws cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id": "heartbeat",
    "MetricStat": {
      "Metric": {
        "Namespace": "Haven",
        "MetricName": "DaemonHeartbeat"
      },
      "Period": 60,
      "Stat": "Maximum"
    }
  }]' \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --region us-east-1

# 2. CPU — EC2 built-in metric, always available
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0901f92161a092f2c \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average \
  --region us-east-1

# 3. Alarm — should show OK (green)
aws cloudwatch describe-alarms \
  --alarm-names haven-daemon-down \
  --region us-east-1 \
  --query "MetricAlarms[0].StateValue"
```

All six widgets should be populated. If any are empty:

- **Heartbeat empty**: Check the cron job (`crontab -l` on EC2). The heartbeat script pushes a `1` to CloudWatch every minute.
- **CPU/Network/Disk empty**: These are built-in EC2 metrics. They take ~5 minutes to appear after instance start. If still empty after 10 minutes, verify the instance ID in the dashboard JSON matches your actual instance.
- **Alarm shows INSUFFICIENT_DATA**: The alarm needs 3 data points before it can evaluate. Wait 3 minutes after enabling the heartbeat.

---

## The Gotcha

### 1. Nested JSON escaping in shell commands

The `put-dashboard` API takes a `--dashboard-body` parameter that is itself a JSON string. If you try to inline it instead of using `file://`, you are escaping JSON inside a shell command:

```bash
# DO NOT DO THIS
aws cloudwatch put-dashboard \
  --dashboard-name "Haven-Operations" \
  --dashboard-body '{"widgets":[{"type":"metric","properties":{"metrics":[["AWS/EC2","CPUUtilization"...]]}}]}'
```

Nested quotes, nested arrays, nested objects. One misplaced escape character and the entire command fails with an unhelpful parse error. The error message will say something like "Invalid JSON" without telling you where.

Use `file://` and keep the JSON in a separate file. Always. The 30 seconds spent creating a file saves 30 minutes of debugging escaped quotes.

### 2. IAM policy gap from Module 07

This was the gotcha that blocked the entire module. The scoped IAM policy created in Module 07 covered `cloudwatch:PutMetricData`, `cloudwatch:GetMetricData`, and `cloudwatch:DescribeAlarms`. It did not cover `cloudwatch:PutDashboard`.

```
An error occurred (AccessDeniedException) when calling the PutDashboard operation:
User: arn:aws:iam::484821991157:user/HavenDev is not authorized to perform:
cloudwatch:PutDashboard
```

The scoped policy was doing its job perfectly -- denying an action we had not explicitly allowed. But it meant we could not create the dashboard without either:

1. Temporarily re-attaching `AdministratorAccess` to update the policy, or
2. Using the AWS Console (which has its own admin login)

We used the Console to update the policy. Then we removed `AdministratorAccess` again. This is the iterative nature of least-privilege that Module 07 warned about. You discover missing permissions by hitting them.

The updated policy from Module 07 now includes:

```json
"cloudwatch:PutDashboard",
"cloudwatch:GetDashboard",
"cloudwatch:ListDashboards",
"cloudwatch:DeleteDashboards"
```

If you are following these modules in order, your Module 07 policy already has these (we backported the fix). If you did Module 07 before Module 08 existed, you will need to update your policy.

### 3. Dashboard widget coordinates matter

Widgets are positioned using `x` and `y` coordinates on a 24-column grid. Heights are in grid units (1 unit = ~66 pixels). If you overlap widgets (same x/y coordinates), they will stack on top of each other in the Console and one will be hidden.

The layout math:

```
Total width: 24 columns
3 widgets per row: 24 / 3 = 8 columns each

Row 1: y=0, widgets at x=0, x=8, x=16
Row 2: y=6, widgets at x=0, x=8, x=16
```

If you change `height` without adjusting the `y` of the next row, widgets will overlap or leave gaps. Plan the grid on paper first.

### 4. The dashboard does not persist custom time ranges

When you zoom into a specific time range on one widget (click and drag), the range applies to all widgets on the dashboard. But if you refresh the page, the range resets to the default (3 hours). There is no way to save a custom time range as the default.

This is a minor annoyance but worth knowing. If you are investigating an incident from 6 hours ago, you will need to adjust the time range every time you refresh the page.

---

## The Result

One URL. Six widgets. Five-second health check.

```
https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1
  #dashboards/dashboard/Haven-Operations
```

What you see:

| Widget | Normal State | Warning Sign |
|--------|-------------|-------------|
| **Daemon Heartbeat** | Solid line at 1.0, no gaps | Drops to 0, gaps in timeline |
| **CPU Utilization** | 5-15% (Haven's normal range on t3.small) | Sustained above 50% |
| **Network In/Out** | Steady bidirectional traffic | Flat line (no API calls), or massive spike (DDoS, runaway loop) |
| **Disk Ops** | Low, periodic spikes (SQLite writes, backups) | Continuous high writes (WAL checkpoint storm, loop crash-restart) |
| **Alarm Status** | Green "Healthy" | Red "DAEMON DOWN" |
| **Quick Reference** | SSH command, log command, backup path | (Static -- always there when you need it) |

The dashboard replaces five SSH commands with one browser tab. It replaces "I wonder if everything is OK" with a definitive answer.

### What healthy looks like

Haven on a t3.small typically shows:

- **CPU**: 8-12% average, spikes to 25-30% during scanner cycles (Lane M scans every 5 minutes, Lane S processes websocket bursts)
- **Network In**: 2-5 MB per 5-minute period (Telegram messages, API responses, price feeds)
- **Network Out**: 0.5-2 MB per 5-minute period (API requests, Telegram alerts, CloudWatch metrics)
- **Disk**: Low but non-zero. SQLite WAL writes every few seconds. Backup dump every 6 hours causes a visible spike.
- **Heartbeat**: Solid green line at 1.0. Any gap means the heartbeat cron failed or the daemon is not running.

### What a problem looks like

We have seen two patterns on the dashboard since deploying it:

1. **Helius credit exhaustion** (visible as network drop): Network Out drops because Lane S stops making API calls. Heartbeat stays green (daemon is alive), CPU drops (less work to do). The dashboard showed the problem 4 hours before we noticed via Telegram (Lane S was just... quiet).

2. **CoinGecko rate limiting** (visible as CPU spike): When CoinGecko returns 429s, the retry logic adds delays. 34 loops contending for one rate-limited API creates a cascade of blocked coroutines. CPU spikes because asyncio is spending cycles managing the backlog. The dashboard showed this as a sustained 40% CPU -- unusual enough to investigate.

Neither of these triggered the daemon-down alarm. The daemon was running fine. It was just degraded. Without the dashboard, degraded performance is invisible until a user (in this case, Brandon) notices that alerts stopped arriving.

---

## Key Takeaways

1. **Dashboards should answer "is everything OK?" in under 5 seconds.** If it takes longer, the dashboard has too much information or not enough structure. Six widgets, one question each.

2. **The text widget is underrated.** Your most-used SSH command, your backup bucket path, your instance ID -- put them on the dashboard. When you are debugging at 2 AM, you do not want to search your notes for the `scp` command.

3. **Build dashboards last.** You need metrics (Module 05), alarms (Module 05), and secrets (Module 06) before a dashboard has anything to show. The dashboard is the capstone of the monitoring stack, not the foundation.

4. **Use `file://` for dashboard JSON, always.** Inline JSON in shell commands is a debugging nightmare. One file, one command, zero escaping issues.

5. **IAM policies need dashboard permissions.** `cloudwatch:PutDashboard` is a separate permission from `cloudwatch:PutMetricData`. If you scoped your IAM policy in Module 07 without dashboard permissions, you will hit `AccessDeniedException` here. This is expected. Iterate.

6. **A dashboard does not replace alerting.** The dashboard shows health. The alarm notifies you of failure. You check the dashboard proactively. The alarm contacts you reactively. You need both. The alarm wakes you up at 3 AM. The dashboard tells you what is wrong when you open your laptop.

---

**Previous module:** [07 - Security Hardening](../07-security-hardening/) -- least-privilege IAM, SSH hardening, and fail2ban.

**Next:** [Capstone](../capstone/) -- final assessment covering all modules.
