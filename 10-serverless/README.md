# Module 10: Serverless Compute — "Haven's Briefings Go Serverless"

> **Maps to:** SAA-C03 Domains 3, 4 | **Services:** Lambda, API Gateway, EventBridge
>
> **Time to complete:** ~45 minutes | **Prerequisites:** Module 01 (VPC basics), Module 06 (IAM roles)

---

## The Problem

Haven generates a morning briefing at 7:00 AM EST and an evening digest at 6:00 PM EST. These are daemon loops — functions inside the 34-loop `haven_daemon.py` that wake up, do 30 seconds of work, and go back to sleep for 12 hours.

Think about the economics of that. The t3.small instance runs 24 hours a day. The briefing code runs for 30 seconds twice a day. That is 60 seconds of useful work per day on a machine that is running for 86,400 seconds. The briefing compute utilization is 0.07%.

The rest of the daemon's 34 loops justify the always-on instance — Lane A scoring, Lane M scanning, Lane S websocket monitoring, paper trade exit polling, price tracking. Those loops run continuously. But the briefing and digest are fundamentally different workloads. They are event-driven (triggered by a schedule), short-lived (seconds, not hours), and stateless (they read from the database, generate a report, send it to Telegram, and exit).

There is a second problem. Haven needs a webhook endpoint. TradingView can send alerts via webhook — when a technical indicator fires, TradingView POSTs a JSON payload to a URL you specify. Right now, Haven has no URL to give TradingView. The EC2 instance does not run a web server (and should not — Module 07 locked down the security group to SSH-only). To receive webhooks, Haven would need to open port 443, install nginx, configure SSL, write a web application, and keep it running alongside the daemon. That is a lot of infrastructure for "receive a POST request and write it to the database."

What if the briefing ran only when scheduled, with zero compute cost between invocations? What if Haven could receive webhooks without running a web server?

---

## The Concept

### Lambda

AWS Lambda is a compute service that runs your code without servers. You upload a function (a Python file, a Node.js file, a Go binary), configure a trigger, and Lambda executes your function when the trigger fires. You pay for the number of invocations and the duration of each invocation, measured in milliseconds. When your function is not running, you pay nothing.

The mental model: Lambda is a function call, not a server. You do not SSH into it. You do not install packages on it. You do not manage its lifecycle. You write a function, deploy it, and forget about the infrastructure.

**Lambda constraints:**

| Constraint | Limit | Haven Impact |
|-----------|-------|--------------|
| Max execution time | 15 minutes | Briefing takes ~30 seconds. Well within limit. |
| Max memory | 10,240 MB | Briefing needs ~128 MB. No issue. |
| Max deployment package | 50 MB (zip), 250 MB (unzipped) | Python + requests + json. Well under. |
| Max concurrent executions | 1,000 (default, can be increased) | Haven runs 2/day. Not a concern. |
| Ephemeral storage (`/tmp`) | 10,240 MB | No persistent state needed. |
| Cold start | 1-3 seconds (Python) | Acceptable for a scheduled briefing. |

Cold starts deserve explanation. When Lambda has not run your function recently (typically 15-45 minutes of inactivity), it needs to spin up a new execution environment: download your code, initialize the runtime, import your modules. This adds 1-3 seconds for Python. After the first invocation, the environment stays "warm" for subsequent invocations, and startup is near-instant.

For Haven's briefing (runs every 12 hours), every invocation will be a cold start. That is fine — nobody cares if the briefing arrives at 7:00:00 AM or 7:00:02 AM. For a webhook endpoint that needs sub-100ms response times, cold starts matter more. We will address this.

### API Gateway

API Gateway gives your Lambda function an HTTP endpoint. You create an API, define routes (e.g., `POST /webhook`), and point them at Lambda functions. API Gateway handles SSL termination, request validation, throttling, and authentication. Your Lambda function receives the HTTP request as an event and returns an HTTP response.

There are two types:

| Type | Use Case | Pricing |
|------|----------|---------|
| **HTTP API** | Simple proxy to Lambda, basic routing | ~$1.00 per million requests |
| **REST API** | Request/response transformation, caching, usage plans, API keys | ~$3.50 per million requests |

For Haven's webhook receiver, HTTP API is the right choice. We need a URL that accepts POST requests and forwards them to Lambda. No transformation, no caching, no API keys (TradingView sends a secret token in the payload for authentication).

### EventBridge (CloudWatch Events)

EventBridge is the scheduler. It replaces the `_scheduler_loop` in Haven's daemon for time-based triggers. You create a rule with a cron expression, point it at a Lambda function, and EventBridge invokes the function on schedule.

```
Haven daemon scheduler:     cron running inside a 24/7 Python process
EventBridge + Lambda:        cron running in AWS, invokes code only when needed
```

Same outcome. Different cost model. The daemon approach costs the full EC2 instance hour. The EventBridge approach costs $0.00 per invocation (first 14 million events/month are free) plus the Lambda execution time (microseconds for a scheduling trigger).

---

## The Build

Everything in this section happens in the **lab VPC** (`10.1.0.0/16`) or in region-level services (Lambda, API Gateway, EventBridge are not VPC-bound by default). Haven's production VPC (`10.0.0.0/16`) is not touched. The Haven daemon is not touched.

### Step 1: Create the IAM role for Lambda

Lambda functions need an IAM role that defines what AWS services they can access. This is the execution role.

```bash
# Create the trust policy (allows Lambda service to assume this role)
cat > /tmp/lambda-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name haven-lab-lambda-role \
  --assume-role-policy-document file:///tmp/lambda-trust-policy.json

# Attach the basic Lambda execution policy (CloudWatch Logs)
aws iam attach-role-policy \
  --role-name haven-lab-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Get the role ARN for later
LAMBDA_ROLE_ARN=$(aws iam get-role \
  --role-name haven-lab-lambda-role \
  --query 'Role.Arn' --output text)
echo "Lambda Role: $LAMBDA_ROLE_ARN"
```

The `AWSLambdaBasicExecutionRole` policy allows the function to write logs to CloudWatch Logs. That is all it needs for this lab. In production, you would add permissions for whatever services the function accesses (DynamoDB, SSM, S3, etc.).

### Step 2: Create the briefing Lambda function

```bash
# Create the function code
mkdir -p /tmp/haven-lab-lambda

cat > /tmp/haven-lab-lambda/lambda_function.py << 'PYEOF'
import json
import datetime
import os

# Sample data simulating Haven's database state
MOCK_HAVEN_STATE = {
    "daemon_status": "running",
    "active_loops": 34,
    "uptime_hours": 127.4,
    "lanes": {
        "A": {"open_trades": 3, "win_rate": 0.41, "total_trades": 34},
        "M": {"open_trades": 5, "win_rate": 0.22, "total_trades": 115},
        "S": {"open_trades": 1, "win_rate": 0.33, "total_trades": 3},
        "EQ": {"open_trades": 2, "win_rate": 0.50, "total_trades": 12}
    },
    "recent_signals": [
        {"symbol": "SOL", "score": 82, "lane": "A", "age_hours": 2.1},
        {"symbol": "LINK", "score": 76, "lane": "M", "age_hours": 8.4},
        {"symbol": "NEWTOKEN", "score": 45, "lane": "S", "age_hours": 0.3}
    ],
    "market": {
        "fear_greed": 42,
        "btc_dominance": 54.2,
        "total_market_cap_b": 2847
    }
}


def lambda_handler(event, context):
    """Generate a simplified Haven morning briefing."""
    now = datetime.datetime.now(datetime.timezone.utc)
    state = MOCK_HAVEN_STATE

    # Build the briefing
    lines = []
    lines.append(f"HAVEN BRIEFING — {now.strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("=" * 50)
    lines.append("")

    # System status
    lines.append(f"Daemon: {state['daemon_status']} ({state['active_loops']} loops)")
    lines.append(f"Uptime: {state['uptime_hours']:.1f} hours")
    lines.append("")

    # Lane summary
    lines.append("LANE STATUS:")
    for lane, data in state["lanes"].items():
        lines.append(
            f"  Lane {lane}: {data['open_trades']} open | "
            f"{data['win_rate']:.0%} WR ({data['total_trades']} trades)"
        )
    lines.append("")

    # Recent signals
    lines.append("RECENT SIGNALS:")
    for sig in state["recent_signals"]:
        lines.append(
            f"  {sig['symbol']:>10} | Score {sig['score']} | "
            f"Lane {sig['lane']} | {sig['age_hours']:.1f}h ago"
        )
    lines.append("")

    # Market context
    mkt = state["market"]
    lines.append("MARKET CONTEXT:")
    lines.append(f"  Fear & Greed: {mkt['fear_greed']}")
    lines.append(f"  BTC Dominance: {mkt['btc_dominance']}%")
    lines.append(f"  Total MCap: ${mkt['total_market_cap_b']:.0f}B")
    lines.append("")
    lines.append(f"Generated by Lambda in {context.memory_limit_in_mb}MB / "
                 f"{context.function_name}")

    briefing = "\n".join(lines)

    # In production, this would send to Telegram via Bot API
    print(briefing)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Briefing generated successfully",
            "timestamp": now.isoformat(),
            "briefing_length": len(briefing),
            "briefing": briefing
        })
    }
PYEOF

# Package it
cd /tmp/haven-lab-lambda && zip -r /tmp/haven-briefing.zip lambda_function.py
```

Wait 10 seconds after creating the IAM role (AWS needs time to propagate it), then create the function:

```bash
# Create the Lambda function
aws lambda create-function \
  --function-name haven-lab-briefing \
  --runtime python3.12 \
  --role $LAMBDA_ROLE_ARN \
  --handler lambda_function.lambda_handler \
  --zip-file fileb:///tmp/haven-briefing.zip \
  --timeout 30 \
  --memory-size 128 \
  --region us-east-1
```

Test it immediately:

```bash
# Invoke the function
aws lambda invoke \
  --function-name haven-lab-briefing \
  --region us-east-1 \
  /tmp/briefing-output.json

# Read the output
cat /tmp/briefing-output.json | python3 -m json.tool
```

You should see the full briefing in the response. The function executed in your account, in a runtime environment that AWS provisioned, ran for a few hundred milliseconds, and shut down. No server. No daemon. No systemctl.

Check the CloudWatch Logs to see the function's `print()` output:

```bash
# List log streams
aws logs describe-log-streams \
  --log-group-name /aws/lambda/haven-lab-briefing \
  --region us-east-1 \
  --query 'logStreams[-1].logStreamName' --output text

# Read the latest log
aws logs get-log-events \
  --log-group-name /aws/lambda/haven-lab-briefing \
  --log-stream-name "$(aws logs describe-log-streams \
    --log-group-name /aws/lambda/haven-lab-briefing \
    --region us-east-1 \
    --query 'logStreams[-1].logStreamName' --output text)" \
  --region us-east-1 \
  --query 'events[*].message'
```

### Step 3: Create the webhook receiver Lambda

This simulates receiving TradingView alerts via HTTP POST.

```bash
cat > /tmp/haven-lab-lambda/webhook_function.py << 'PYEOF'
import json
import datetime
import hashlib


def lambda_handler(event, context):
    """Receive and validate a TradingView webhook alert."""
    # API Gateway sends the request details in the event
    http_method = event.get("requestContext", {}).get("http", {}).get("method", "UNKNOWN")
    body_raw = event.get("body", "")
    is_base64 = event.get("isBase64Encoded", False)

    # Parse the body
    try:
        if is_base64:
            import base64
            body_raw = base64.b64decode(body_raw).decode("utf-8")
        body = json.loads(body_raw) if body_raw else {}
    except json.JSONDecodeError:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Invalid JSON in request body"})
        }

    # Validate the secret token (TradingView sends this in the payload)
    expected_token = "haven-webhook-secret-2026"
    received_token = body.get("token", "")
    if received_token != expected_token:
        print(f"REJECTED: invalid token from {event.get('requestContext', {}).get('http', {}).get('sourceIp', 'unknown')}")
        return {
            "statusCode": 401,
            "body": json.dumps({"error": "Invalid webhook token"})
        }

    # Extract the alert data
    alert = {
        "symbol": body.get("symbol", "UNKNOWN"),
        "action": body.get("action", "UNKNOWN"),  # BUY, SELL, ALERT
        "price": body.get("price", 0),
        "indicator": body.get("indicator", "UNKNOWN"),
        "timeframe": body.get("timeframe", "UNKNOWN"),
        "received_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "alert_id": hashlib.md5(
            f"{body.get('symbol','')}{body.get('price',0)}{datetime.datetime.now().isoformat()}".encode()
        ).hexdigest()[:12]
    }

    # In production, this would write to DynamoDB or SQS
    print(f"ACCEPTED: {alert['symbol']} {alert['action']} @ {alert['price']} "
          f"[{alert['indicator']} {alert['timeframe']}]")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "accepted",
            "alert_id": alert["alert_id"],
            "message": f"Alert received: {alert['symbol']} {alert['action']}"
        })
    }
PYEOF

cd /tmp/haven-lab-lambda && zip -r /tmp/haven-webhook.zip webhook_function.py

aws lambda create-function \
  --function-name haven-lab-webhook \
  --runtime python3.12 \
  --role $LAMBDA_ROLE_ARN \
  --handler webhook_function.lambda_handler \
  --zip-file fileb:///tmp/haven-webhook.zip \
  --timeout 10 \
  --memory-size 128 \
  --region us-east-1
```

Test it directly (without API Gateway, for now):

```bash
# Simulate a TradingView webhook payload
aws lambda invoke \
  --function-name haven-lab-webhook \
  --payload '{
    "body": "{\"token\": \"haven-webhook-secret-2026\", \"symbol\": \"SOLUSDT\", \"action\": \"BUY\", \"price\": 187.50, \"indicator\": \"RSI_oversold\", \"timeframe\": \"4h\"}"
  }' \
  --region us-east-1 \
  /tmp/webhook-output.json

cat /tmp/webhook-output.json | python3 -m json.tool

# Test with a bad token
aws lambda invoke \
  --function-name haven-lab-webhook \
  --payload '{
    "body": "{\"token\": \"wrong-token\", \"symbol\": \"BTCUSDT\", \"action\": \"SELL\", \"price\": 65000}"
  }' \
  --region us-east-1 \
  /tmp/webhook-rejected.json

cat /tmp/webhook-rejected.json | python3 -m json.tool
```

The first should return `statusCode: 200` with `"status": "accepted"`. The second should return `statusCode: 401`.

### Step 4: Create the API Gateway

Now give the webhook function a public URL.

```bash
# Create an HTTP API
API_ID=$(aws apigatewayv2 create-api \
  --name haven-lab-webhook-api \
  --protocol-type HTTP \
  --region us-east-1 \
  --query 'ApiId' --output text)
echo "API ID: $API_ID"

# Create the Lambda integration
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:us-east-1:$(aws sts get-caller-identity --query Account --output text):function:haven-lab-webhook" \
  --payload-format-version 2.0 \
  --region us-east-1 \
  --query 'IntegrationId' --output text)
echo "Integration: $INTEGRATION_ID"

# Create the POST /webhook route
aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "POST /webhook" \
  --target "integrations/$INTEGRATION_ID" \
  --region us-east-1

# Create a default stage (auto-deploy)
aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy \
  --region us-east-1

# Grant API Gateway permission to invoke the Lambda
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws lambda add-permission \
  --function-name haven-lab-webhook \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:${ACCOUNT_ID}:${API_ID}/*" \
  --region us-east-1

# Get the API endpoint
API_ENDPOINT=$(aws apigatewayv2 get-api \
  --api-id $API_ID \
  --region us-east-1 \
  --query 'ApiEndpoint' --output text)
echo "Webhook URL: ${API_ENDPOINT}/webhook"
```

Now test it with `curl` — from anywhere, not just inside the VPC:

```bash
# Send a valid webhook
curl -X POST "${API_ENDPOINT}/webhook" \
  -H "Content-Type: application/json" \
  -d '{
    "token": "haven-webhook-secret-2026",
    "symbol": "SOLUSDT",
    "action": "BUY",
    "price": 187.50,
    "indicator": "RSI_oversold",
    "timeframe": "4h"
  }'

# Send an invalid webhook (bad token)
curl -X POST "${API_ENDPOINT}/webhook" \
  -H "Content-Type: application/json" \
  -d '{
    "token": "bad-token",
    "symbol": "BTCUSDT",
    "action": "SELL",
    "price": 65000
  }'
```

The first returns `{"status": "accepted", ...}`. The second returns `{"error": "Invalid webhook token"}` with a 401 status.

You just created a public HTTPS endpoint, backed by a Lambda function, with zero servers. No nginx. No SSL certificates. No security group changes. No port forwarding. API Gateway handles all of it.

This is the URL you would give TradingView: `${API_ENDPOINT}/webhook`. When TradingView's indicator fires, it POSTs to this URL, API Gateway routes it to Lambda, Lambda validates the token and processes the alert.

### Step 5: Schedule the briefing with EventBridge

```bash
# Create a scheduled rule (every day at 12:00 UTC = 7:00 AM EST)
aws events put-rule \
  --name haven-lab-briefing-schedule \
  --schedule-expression "cron(0 12 * * ? *)" \
  --state ENABLED \
  --region us-east-1

# Add the Lambda function as the target
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws events put-targets \
  --rule haven-lab-briefing-schedule \
  --targets "Id=1,Arn=arn:aws:lambda:us-east-1:${ACCOUNT_ID}:function:haven-lab-briefing" \
  --region us-east-1

# Grant EventBridge permission to invoke the Lambda
aws lambda add-permission \
  --function-name haven-lab-briefing \
  --statement-id eventbridge-schedule \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:us-east-1:${ACCOUNT_ID}:rule/haven-lab-briefing-schedule" \
  --region us-east-1
```

The briefing function will now execute automatically at 7:00 AM EST every day. Cost: $0.00 for the EventBridge rule, $0.0000002 per Lambda invocation (literally two-tenths of a millionth of a dollar), plus $0.0000166667 per GB-second of compute. At 128MB and 1 second of runtime, the daily cost is approximately $0.000002. Two millionths of a dollar per day. The annual cost is less than one cent.

Compare that to the EC2 approach: even a `t3.nano` running 24/7 for one cron job costs ~$3.80/month.

---

## The Teardown

```bash
# 1. Remove EventBridge rule and targets
aws events remove-targets \
  --rule haven-lab-briefing-schedule \
  --ids 1 \
  --region us-east-1
aws events delete-rule \
  --name haven-lab-briefing-schedule \
  --region us-east-1

# 2. Delete API Gateway
aws apigatewayv2 delete-api \
  --api-id $API_ID \
  --region us-east-1

# 3. Delete Lambda functions
aws lambda delete-function \
  --function-name haven-lab-briefing \
  --region us-east-1
aws lambda delete-function \
  --function-name haven-lab-webhook \
  --region us-east-1

# 4. Delete CloudWatch Log groups (Lambda creates these automatically)
aws logs delete-log-group \
  --log-group-name /aws/lambda/haven-lab-briefing \
  --region us-east-1
aws logs delete-log-group \
  --log-group-name /aws/lambda/haven-lab-webhook \
  --region us-east-1

# 5. Delete IAM role (must detach policies first)
aws iam detach-role-policy \
  --role-name haven-lab-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role \
  --role-name haven-lab-lambda-role

# 6. Clean up temp files
rm -rf /tmp/haven-lab-lambda /tmp/haven-briefing.zip /tmp/haven-webhook.zip \
       /tmp/briefing-output.json /tmp/webhook-output.json /tmp/webhook-rejected.json \
       /tmp/lambda-trust-policy.json

# 7. Verify
aws lambda list-functions --region us-east-1 \
  --query 'Functions[?contains(FunctionName, `haven-lab`)]'
aws apigatewayv2 get-apis --region us-east-1 \
  --query 'Items[?contains(Name, `haven-lab`)]'
# Both should return empty arrays
```

---

## The Gotcha

### 1. Lambda has a 15-minute maximum timeout

Haven's briefing takes 30 seconds. No problem. But if you tried to run one of Haven's continuous daemon loops as a Lambda function — say, the Lane S websocket listener that runs indefinitely — Lambda would kill it after 15 minutes. Lambda is for short-lived, event-driven workloads. Long-running processes belong on EC2 or ECS.

The 15-minute limit is hard. You cannot increase it. If your function needs more time, you must redesign: break the work into smaller chunks, use Step Functions to orchestrate multiple Lambda invocations, or move to a container-based service.

### 2. Cold starts are real

The briefing function's first invocation after a period of inactivity takes 1-3 seconds longer than subsequent invocations. For a scheduled briefing, this is invisible. For an API endpoint receiving user traffic, 3 seconds of latency on the first request is noticeable.

Mitigation options:
- **Provisioned Concurrency**: Keep N execution environments warm at all times. Eliminates cold starts but costs money (you pay for the provisioned environments even when idle). This defeats the serverless cost model.
- **Lambda SnapStart** (Java only): Snapshots the initialized runtime to reduce cold start time.
- **Keep functions small**: Fewer imports = faster cold start. A function that imports `pandas`, `numpy`, and `boto3` cold-starts in 3-5 seconds. A function that imports only `json` cold-starts in under 1 second.

### 3. Dependencies require Lambda Layers or container images

The lab functions use only Python standard library modules. In production, Haven's briefing would need `aiohttp` (for Telegram Bot API), `aiosqlite` or `asyncpg` (for database), and possibly `cryptography` (for API key decryption). You cannot `pip install` inside a Lambda function.

Options:
- **Lambda Layers**: Zip your dependencies into a layer, attach it to the function. The layer is mounted at `/opt/python/` and added to the Python path. Up to 5 layers per function.
- **Container image**: Package your function as a Docker image (up to 10 GB). Lambda runs the container. Full control over the runtime environment.
- **Inline packaging**: Include the dependencies in your deployment zip alongside `lambda_function.py`. Works for small dependencies but gets unwieldy.

### 4. API Gateway has two types — know which one you are using

REST API and HTTP API look similar but differ in features and cost:

| Feature | REST API | HTTP API |
|---------|----------|----------|
| Price per million | $3.50 | $1.00 |
| Request/response transformation | Yes | No |
| Caching | Yes | No |
| Usage plans + API keys | Yes | No |
| WebSocket support | Separate (WebSocket API) | No |
| JWT authorizer | No (use Lambda authorizer) | Yes (native) |

The exam asks about this. "The company needs to minimize API costs" points to HTTP API. "The company needs request transformation and caching" points to REST API. We used HTTP API because Haven's webhook is a simple proxy — it does not need transformation or caching.

---

## The Result

### What we built

```
EventBridge Rule (cron: 0 12 * * ? *)
  |
  +--triggers--> Lambda: haven-lab-briefing
                   - 128 MB, 30s timeout
                   - Generates morning briefing
                   - Runs once/day, costs ~$0.01/year

API Gateway (HTTP API)
  |
  POST /webhook --> Lambda: haven-lab-webhook
                      - 128 MB, 10s timeout
                      - Validates token, processes alert
                      - Costs $1/million requests
```

### What Haven's production architecture would look like

```
EventBridge Rules:
  - 7:00 AM EST: Morning briefing Lambda
  - 6:00 PM EST: Evening digest Lambda
  - Every 3 days: Intelligence digest Lambda

API Gateway (HTTP API):
  - POST /webhook/tradingview --> Lambda (validate + write to SQS)
  - POST /webhook/cryptopanic --> Lambda (news feed events)

SQS Queue:
  - Validated webhooks queued for daemon processing
  - Daemon polls SQS instead of running a web server

Cost: ~$1/month (vs $0/month incremental on existing EC2,
       but with zero coupling to daemon uptime)
```

The key insight is not that serverless is cheaper (for Haven's scale, it is roughly equivalent). The insight is that serverless **decouples** the briefing from the daemon. If the daemon crashes, the briefing still runs. If you need to restart the daemon for a migration, the webhook endpoint stays up. Each function is independently deployable, independently scalable, and independently monitored.

---

## Key Takeaways

1. **Lambda is for event-driven, short-lived workloads.** If your code runs for seconds in response to an event (HTTP request, schedule, file upload, queue message), Lambda is the right choice. If your code runs continuously (Haven's 34 daemon loops), EC2 or ECS is the right choice.

2. **The 15-minute timeout is a hard constraint.** Design around it. If your workload takes longer, break it into steps (Step Functions), use a container service, or rethink the architecture.

3. **Cold starts are a latency concern, not a correctness concern.** The function runs correctly regardless of cold start. But if your API endpoint has a p99 latency requirement of 200ms, cold starts will violate it unless you use Provisioned Concurrency.

4. **API Gateway HTTP API is cheaper and simpler than REST API.** Use HTTP API unless you specifically need REST API features (caching, request transformation, usage plans). The exam tests this distinction.

5. **EventBridge replaces cron for cloud-native scheduling.** No server needed. No daemon needed. The rule fires, the function runs, you pay for the invocation. For workloads that run infrequently (daily, hourly), this is dramatically cheaper than keeping an instance running.

6. **Serverless is about decoupling, not just cost.** The briefing function works whether or not the daemon is running. The webhook endpoint works whether or not the EC2 instance is up. Each component fails independently.

---

## Exam Lens

### SAA-C03 Domain Mapping

| Domain | Weight | This Module Covers |
|--------|--------|--------------------|
| Domain 3: Design High-Performing Architectures | 24% | Lambda scaling, API Gateway types, cold start mitigation |
| Domain 4: Design Cost-Optimized Architectures | 30% | Lambda vs EC2 cost comparison, HTTP vs REST API pricing |

### Scenario Questions

**Q1:** A company runs a batch job that processes uploaded images. The job takes 2-3 minutes per image. Images are uploaded 50-100 times per day. The current solution uses a t3.medium EC2 instance running 24/7. How should they reduce costs?

**A:** Use Amazon S3 event notifications to trigger an AWS Lambda function when an image is uploaded. Lambda processes the image (well within the 15-minute limit at 2-3 minutes). Cost drops from ~$30/month (EC2 24/7) to pennies (100 invocations/day x 3 minutes x 256MB = ~$0.10/month).

---

**Q2:** A company needs a REST API that handles 10 million requests per day with sub-50ms latency. The API reads from a DynamoDB table. They want to minimize costs. Which API Gateway type should they use?

**A:** API Gateway HTTP API. It costs $1.00 per million requests vs $3.50 for REST API. At 10 million requests/day, that is $300/month vs $1,050/month. The sub-50ms latency requirement is met by both types (the latency is dominated by DynamoDB, not API Gateway). Use HTTP API unless REST API features are specifically needed.

---

**Q3:** A company has a Lambda function that processes messages from an SQS queue. The function takes 20 minutes to process each message. Invocations are failing with a timeout error. What should they do?

**A:** Lambda's maximum timeout is 15 minutes. The function cannot be extended beyond this. Options: (1) Break the processing into smaller steps using AWS Step Functions, where each step is a separate Lambda invocation under 15 minutes. (2) Move the processing to Amazon ECS or EC2 if it cannot be decomposed. Do NOT increase the Lambda timeout — 15 minutes is the hard maximum.

---

**Q4:** A company has a Lambda function behind API Gateway that experiences 3-second cold starts. This causes poor user experience for the first request after periods of inactivity. What is the most effective solution?

**A:** Configure Provisioned Concurrency for the Lambda function. This keeps a specified number of execution environments initialized and ready, eliminating cold starts. The tradeoff is cost — you pay for the provisioned environments whether or not they handle requests. For predictable traffic patterns, this is cost-effective. For highly variable traffic, consider whether the cold start latency is actually a business problem.

---

**Q5:** A company wants to run a scheduled task every 6 hours that queries an RDS database, generates a report, and emails it to stakeholders. The task takes 45 seconds. They currently run it as a cron job on an EC2 instance. How should they modernize this?

**A:** Use Amazon EventBridge (CloudWatch Events) with a rate expression (`rate(6 hours)`) to trigger a Lambda function. The function queries RDS (using RDS Proxy for connection management), generates the report, and uses Amazon SES to send the email. This eliminates the need for the EC2 instance if it was only running the cron job. Lambda's 15-minute limit is not a concern at 45 seconds.

### Know the Difference

| Concept A | Concept B | Key Distinction |
|-----------|-----------|-----------------|
| **Lambda** | **EC2** | Lambda = event-driven, max 15 min, pay per invocation. EC2 = always-on, no time limit, pay per hour. |
| **HTTP API** | **REST API** | HTTP API = simpler, cheaper ($1/M). REST API = caching, transformation, usage plans ($3.50/M). |
| **Lambda cold start** | **Provisioned Concurrency** | Cold start = 1-3s delay on first invocation. Provisioned Concurrency = pre-warmed environments, no delay, costs money when idle. |
| **EventBridge** | **CloudWatch Events** | Same service, rebranded. EventBridge is the current name. CloudWatch Events still works but is legacy terminology. |
| **Lambda Layers** | **Container images** | Layers = share dependencies across functions (5 layer limit). Container images = full OS control (up to 10 GB). |
| **Lambda@Edge** | **CloudFront Functions** | Lambda@Edge = runs at CloudFront edge, up to 30s, full Node/Python. CloudFront Functions = sub-ms, lightweight JS only, cheaper. |

### Cost Traps the Exam Tests

1. **Lambda free tier is generous.** 1 million requests and 400,000 GB-seconds per month, free, forever. Most small workloads never exceed the free tier.

2. **Provisioned Concurrency kills the serverless cost model.** If you provision 10 environments at 128MB 24/7, you pay ~$5.50/month regardless of invocations. Only use it when cold start latency is a business requirement.

3. **API Gateway costs add up at scale.** 100 million requests/month on REST API = $350/month just for API Gateway (before Lambda costs). HTTP API cuts this to $100. At very high scale, consider ALB + Lambda (ALB is cheaper per request above ~1B requests/month).

4. **Lambda execution time rounds up to the nearest 1ms.** A 1.1ms function is billed as 2ms. Optimize your code for fast execution if you are running millions of invocations.

5. **CloudWatch Logs from Lambda are not free.** Lambda automatically writes logs to CloudWatch Logs. At high invocation volume, log ingestion costs ($0.50/GB) can exceed the Lambda compute cost. Set log retention periods and avoid logging large payloads.

6. **NAT Gateway charges apply if Lambda is in a VPC.** If your Lambda function needs to access the internet (e.g., calling external APIs) AND is deployed inside a VPC (e.g., to reach RDS), it needs a NAT Gateway. NAT Gateway costs $0.045/hour + $0.045/GB processed. This is often the hidden cost that makes VPC-attached Lambdas expensive.

---

**Previous module:** [09 - Databases](../09-databases/) -- RDS, Aurora, and DynamoDB for managed data storage.

**Next module:** [11 - Load Balancing](../11-load-balancing/) -- ALB, Auto Scaling Groups, and Launch Templates for scalable web traffic.
