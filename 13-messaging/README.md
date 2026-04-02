# Module 13: Messaging & Decoupling

> What if Haven's 34 daemon loops communicated through managed message queues instead of sharing a SQLite database and in-memory asyncio.Queues?

**Maps to:** SAA-C03 Domains 2, 3 | **Services:** SQS, SNS, EventBridge
**Time to complete:** ~30 minutes
**Prerequisites:** Module 01 (VPC & Compute), familiarity with Haven's daemon architecture

---

## The Problem

Haven's daemon is a single Python process running 34 async loops. They communicate in two ways, and both have problems.

### Shared Database Problem

All 34 loops read from and write to the same SQLite file (`data/haven.db`). When the Lane S pool listener detects a new token launch and writes a row to `signal_outcomes`, the outcome checker loop picks it up on its next 60-second cycle. This works, but SQLite uses file-level locking. When the price monitor is writing MFE/MAE updates for 50 tracked tokens, the scanner loop's INSERT blocks until the lock releases. We have seen this -- the daemon logs show `database is locked` warnings during peak activity.

The deeper issue: if the daemon crashes (and it has -- `asyncio.gather` without `return_exceptions=True` took down all 34 loops when one crashed), everything in the SQLite write-ahead log that has not been checkpointed is at risk. The database is the communication channel AND the persistence layer AND the single point of failure.

### In-Memory Queue Problem

Lane S uses `asyncio.Queue` to pass detected launches from the websocket listener to the scoring filter. This is fast and elegant. It is also ephemeral. When the daemon restarts (which happens during deployments, crashes, or EC2 reboots), the queue vanishes. Any launches sitting in the queue at crash time are lost. We have no way to know what was lost because the queue has no persistence, no logging, no dead-letter handling.

This is the fundamental tradeoff: SQLite is durable but slow under contention. asyncio.Queue is fast but volatile. What if we had something that was both durable AND fast, with built-in retry logic, dead-letter handling, and the ability to decouple producers from consumers entirely?

### The Architecture We Have

```
[Lane S Listener] --asyncio.Queue--> [Lane S Scorer] --SQLite INSERT--> [Paper Trading Loop]
[Scanner Loop] --SQLite INSERT--> [Outcome Checker] --SQLite UPDATE--> [Alert History]
[Scheduler Loop] --direct call--> [Briefing Generator] --Telegram API--> [User]
```

Every arrow is a tight coupling. The producer must know who the consumer is. If the consumer is slow, the producer blocks (SQLite) or drops messages (Queue overflow). If we want to add a new consumer (say, a logging service that records every signal), we modify the producer code.

### The Architecture We Want

```
[Lane S Listener] --SQS Queue--> [Lane S Scorer]
                              \--> [Signal Logger]  (fan-out: anyone can subscribe)

[Scanner Loop] --SNS Topic--> [SQS: Paper Trading]
                           \--> [SQS: Outcome Tracker]
                           \--> [SQS: Analytics]    (add consumers without touching producer)

[EventBridge Rule: cron(0 12 * * ? *)] --> [Lambda: Morning Briefing]
                                                                      (no daemon needed for scheduling)
```

Producers publish. Consumers subscribe. They do not know about each other. This is **decoupling**, and it is one of the most tested architectural patterns on SAA-C03.

---

## The Concept

### SQS: Simple Queue Service

**SQS** is a fully managed message queue. A producer sends a message. It sits in the queue until a consumer retrieves it. After the consumer processes it, the consumer deletes it. If the consumer crashes before deleting it, the message reappears in the queue after the **visibility timeout** expires.

Think of it as a to-do list. Items go on the list. Workers pull items off. If a worker takes an item and dies, the item goes back on the list for another worker.

#### Standard vs FIFO -- The Most-Tested SQS Comparison

| Feature | Standard Queue | FIFO Queue |
|---------|---------------|------------|
| Message ordering | **Best effort** -- messages may arrive out of order | **Strict FIFO** -- first in, first out, guaranteed |
| Delivery guarantee | **At-least-once** -- a message may be delivered more than once | **Exactly-once** -- each message delivered exactly once |
| Throughput | Virtually unlimited | 300 messages/second (3,000 with batching) |
| Deduplication | Not built-in | Built-in (5-minute dedup window) |
| Use case | High-volume, order not critical | Order matters, no duplicates allowed |

**For Haven:** Standard queue for most things. Lane S launches do not need strict ordering -- if launch A is scored before launch B, that is fine. But paper trade execution might need FIFO -- you do not want to process a sell before the buy.

**Exam trap:** "The application processes 50,000 messages per second and order does not matter." The answer is Standard, not FIFO. FIFO caps at 300/second (3,000 batched). Many candidates pick FIFO because it "sounds better" and get caught by the throughput limit.

#### Visibility Timeout

When a consumer receives a message, the message becomes invisible to other consumers for the **visibility timeout** period (default: 30 seconds). If the consumer processes and deletes the message within that window, done. If the consumer crashes, the timeout expires, and the message becomes visible again for another consumer to pick up.

This is how SQS guarantees message processing without acknowledgment protocols. The consumer "leases" the message. If the lease expires without deletion, the message is back in play.

**Haven analogy:** When the outcome checker picks up a signal to evaluate, it effectively has a 30-second lease. If it crashes mid-evaluation, the signal goes back to the queue. Without SQS, that signal would be stuck in `pending` state in SQLite forever (which is exactly what happened -- we had 2,560+ stuck signals before wiring in the outcome checker loop).

#### Dead-Letter Queues (DLQ)

A DLQ is a separate SQS queue where messages go after failing processing a configurable number of times (the **maxReceiveCount**). Instead of a poison message being retried forever (consumer crashes, message reappears, consumer crashes again, infinite loop), after N failures, the message moves to the DLQ for manual investigation.

**Haven analogy:** Haven's daemon has no DLQ concept. When the CryptoPanic API returns bad data and the news processor crashes, the error is logged and the message is lost. With SQS + DLQ, the bad message would survive in the DLQ for us to inspect later.

#### Long Polling vs Short Polling

| Polling Type | Behavior | Cost |
|-------------|----------|------|
| **Short polling** (default) | Returns immediately, even if queue is empty | More API calls = more cost |
| **Long polling** (recommended) | Waits up to 20 seconds for a message to arrive | Fewer API calls = less cost |

**Always use long polling** (`WaitTimeSeconds: 20`). There is no reason to use short polling in production. The exam will present a "reduce SQS costs" scenario -- long polling is the answer.

### SNS: Simple Notification Service

**SNS** is pub/sub. A publisher sends a message to a **topic**. All **subscribers** to that topic receive the message. Subscribers can be SQS queues, Lambda functions, HTTP endpoints, email addresses, or SMS numbers.

The key difference from SQS: **fan-out**. One message to an SNS topic can trigger 10 different consumers simultaneously. With SQS alone, one message goes to one consumer.

**Haven use case:** When the scanner generates a Lane A signal, it could publish to an SNS topic "haven-signals." Subscribers:
- SQS queue for paper trading (enters the position)
- SQS queue for outcome tracking (starts the evaluation clock)
- SQS queue for analytics (records signal metadata)
- Email subscription (sends Brandon a notification)

All four consumers get the same message. The scanner does not know any of them exist. Adding a fifth consumer means adding a subscription, not modifying scanner code.

#### SNS + SQS Fan-Out Pattern

This is the most common architecture pattern involving SNS on the exam:

```
[Producer] --> [SNS Topic] --> [SQS Queue A] --> [Consumer A]
                           --> [SQS Queue B] --> [Consumer B]
                           --> [SQS Queue C] --> [Consumer C]
```

Why not publish directly to multiple SQS queues? Because the producer would need to know about each queue and send the message N times. With SNS in the middle, the producer sends once. SNS handles the fan-out. If Consumer D shows up next week, add a subscription. Zero producer changes.

#### SNS Message Filtering

Subscribers can set **filter policies** to receive only messages matching certain attributes. Without filtering, every subscriber gets every message. With filtering:

```json
{
  "lane": ["lane_a"],
  "score": [{"numeric": [">=", 75]}]
}
```

This subscriber only receives Lane A signals with score >= 75. Lane M and Lane S messages are filtered out at SNS -- they never reach this subscriber's SQS queue.

### EventBridge: Event Bus

**EventBridge** is the evolution of CloudWatch Events. It is an event bus that routes events from sources to targets based on rules. Think of it as a smarter SNS with pattern matching, scheduling, and integration with 100+ AWS services and SaaS partners.

#### EventBridge for Scheduling

Haven's daemon runs a `_scheduler_loop` that checks the clock every 30 seconds and triggers briefings at 7:00 AM, digests at 6:00 PM, and intelligence digests every 3 days at 8:00 AM. This works, but it requires the daemon to be running. If the daemon crashes at 6:55 PM, no evening digest.

EventBridge can replace this with cron rules:

```
Rule: "haven-morning-briefing"
Schedule: cron(0 12 * * ? *)    # 7 AM EST = 12 UTC
Target: Lambda function that generates the briefing

Rule: "haven-evening-digest"
Schedule: cron(0 23 * * ? *)    # 6 PM EST = 23 UTC
Target: Lambda function that generates the digest
```

The scheduler runs in AWS infrastructure, not in your daemon. If the daemon is down for maintenance, the briefing still fires.

#### EventBridge Event Patterns

EventBridge can also route events by content. An event pattern matches against event JSON:

```json
{
  "source": ["haven.scanner"],
  "detail-type": ["signal.generated"],
  "detail": {
    "lane": ["lane_s"],
    "score": [{"numeric": [">", 30]}]
  }
}
```

This rule fires only for Lane S signals with score above 30. Different rules can route different events to different targets -- all without the producer knowing about the routing logic.

---

## The Build

All resources in this module are global or regional services (SQS, SNS, EventBridge). They do not live inside a VPC. We use the **lab VPC (10.1.0.0/16)** naming convention for tagging, but the queues and topics are accessible from anywhere with the right IAM permissions.

### Step 1: Create a Standard SQS Queue

```bash
# Create the queue
aws sqs create-queue \
  --queue-name haven-lab-signals \
  --attributes '{
    "VisibilityTimeout": "60",
    "MessageRetentionPeriod": "86400",
    "ReceiveMessageWaitTimeSeconds": "20"
  }' \
  --tags '{
    "Environment": "lab",
    "Module": "13"
  }'

# Save the queue URL from the output
# Example: https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals
```

Configuration choices:
- **`VisibilityTimeout: 60`** -- Consumer has 60 seconds to process before the message reappears. Haven's outcome evaluations take 5-10 seconds, so 60 seconds gives generous headroom.
- **`MessageRetentionPeriod: 86400`** -- Messages survive 24 hours if not consumed. Default is 4 days; max is 14 days.
- **`ReceiveMessageWaitTimeSeconds: 20`** -- Long polling. The consumer waits up to 20 seconds for a message instead of returning immediately on empty queue. Saves money.

### Step 2: Send a Haven Signal Message

```bash
# Simulate a Haven Lane A signal
aws sqs send-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals \
  --message-body '{
    "lane": "lane_a",
    "token": "BONK",
    "token_address": "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263",
    "score": 82,
    "callers": 3,
    "wallets": 7,
    "timestamp": "2026-04-02T14:30:00Z",
    "source": "haven.scanner"
  }' \
  --message-attributes '{
    "lane": {
      "DataType": "String",
      "StringValue": "lane_a"
    },
    "score": {
      "DataType": "Number",
      "StringValue": "82"
    }
  }'

# Output:
# "MessageId": "a1b2c3d4-...",
# "MD5OfMessageBody": "..."
```

The message is now in the queue. It will stay there until a consumer retrieves it or 24 hours pass (retention period).

### Step 3: Receive and Process the Message

```bash
# Receive the message (long poll -- waits up to 20 seconds)
aws sqs receive-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals \
  --max-number-of-messages 1 \
  --message-attribute-names All \
  --wait-time-seconds 20

# Output includes:
# "Body": "{\"lane\": \"lane_a\", \"token\": \"BONK\", ...}",
# "ReceiptHandle": "AQEBw..."    <-- Need this to delete
```

**Save the ReceiptHandle.** You need it to delete the message after processing.

```bash
# After "processing" the signal, delete it from the queue
aws sqs delete-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals \
  --receipt-handle "AQEBw..."
```

If you do NOT delete the message, it becomes visible again after the visibility timeout (60 seconds). This is the retry mechanism -- if your consumer crashes before deletion, the message is not lost.

### Step 4: Create a FIFO Queue for Comparison

```bash
# FIFO queue names MUST end in .fifo
aws sqs create-queue \
  --queue-name haven-lab-trades.fifo \
  --attributes '{
    "FifoQueue": "true",
    "ContentBasedDeduplication": "true",
    "VisibilityTimeout": "60",
    "ReceiveMessageWaitTimeSeconds": "20"
  }'
```

Now send two messages and observe ordering:

```bash
# Send message 1
aws sqs send-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-trades.fifo \
  --message-body '{"action": "BUY", "token": "BONK", "amount": 0.05}' \
  --message-group-id "paper-trades"

# Send message 2
aws sqs send-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-trades.fifo \
  --message-body '{"action": "SELL", "token": "BONK", "amount": 0.025}' \
  --message-group-id "paper-trades"

# Receive -- guaranteed to get BUY before SELL
aws sqs receive-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-trades.fifo \
  --max-number-of-messages 2
```

The FIFO queue guarantees you receive BUY before SELL. A Standard queue might give you SELL first. For paper trade execution, order matters -- you cannot sell what you have not bought.

### Step 5: Create an EventBridge Scheduled Rule

```bash
# Create a rule that fires every 5 minutes (simulating Haven's scheduler)
aws events put-rule \
  --name haven-lab-heartbeat \
  --schedule-expression "rate(5 minutes)" \
  --state ENABLED \
  --description "Lab: simulates Haven daemon scheduler"

# Target the SQS queue (EventBridge puts a message in the queue on schedule)
aws events put-targets \
  --rule haven-lab-heartbeat \
  --targets '[{
    "Id": "sqs-target",
    "Arn": "arn:aws:sqs:us-east-1:484821991157:haven-lab-signals",
    "Input": "{\"source\": \"eventbridge\", \"type\": \"heartbeat\", \"message\": \"Haven scheduler tick\"}"
  }]'
```

Now, every 5 minutes, EventBridge will drop a message into your SQS queue. No daemon required. No process to keep alive. AWS infrastructure handles the scheduling.

```bash
# Wait 5 minutes, then check:
aws sqs receive-message \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals \
  --max-number-of-messages 10

# You should see the heartbeat message from EventBridge
```

**Grant EventBridge permission to send to SQS:**

```bash
# SQS needs a resource policy allowing EventBridge to send messages
aws sqs set-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals \
  --attributes '{
    "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"events.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"arn:aws:sqs:us-east-1:484821991157:haven-lab-signals\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"arn:aws:events:us-east-1:484821991157:rule/haven-lab-heartbeat\"}}}]}"
  }'
```

### Step 6: Observe the Flow

At this point, you have built a working event-driven pipeline:

```
[EventBridge: every 5 min] --> [SQS: haven-lab-signals] --> [You, polling with CLI]
[Manual: send-message]     --> [SQS: haven-lab-signals] --> [You, polling with CLI]
```

In production, the CLI consumer would be a Lambda function or an ECS container. The architecture is identical -- only the consumer changes.

```bash
# Check queue depth (how many messages are waiting)
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

# ApproximateNumberOfMessages = messages waiting to be consumed
# ApproximateNumberOfMessagesNotVisible = messages currently being processed
```

---

## The Teardown

```bash
# Delete SQS queues
aws sqs delete-queue \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-signals

aws sqs delete-queue \
  --queue-url https://sqs.us-east-1.amazonaws.com/484821991157/haven-lab-trades.fifo

# Remove EventBridge targets first (required before deleting the rule)
aws events remove-targets \
  --rule haven-lab-heartbeat \
  --ids sqs-target

# Delete EventBridge rule
aws events delete-rule \
  --name haven-lab-heartbeat
```

SQS queue deletion is immediate. EventBridge rule deletion is immediate. No propagation delay. Total teardown time: ~30 seconds.

---

## The Gotcha

### At-Least-Once Delivery Will Burn You

SQS Standard queues can deliver the same message **more than once**. This is not a bug. It is a design tradeoff for unlimited throughput and high availability.

Imagine Haven's paper trading consumer receives a "BUY BONK at $0.00002" message, enters the position, but then receives the SAME message again (duplicate delivery). Without idempotency, you now have two positions in the same token. Your PnL reporting is wrong. Your max-concurrent check thinks you have one fewer slot available.

Haven already has this problem in a different form. The `check_dedup()` function exists specifically because the scanner can fire on the same token multiple times in quick succession. Moving to SQS Standard does not solve the dedup problem -- it makes it the consumer's responsibility.

**Solutions:**
- **FIFO queue** -- guarantees exactly-once delivery. But capped at 300 msg/sec.
- **Idempotent consumer** -- check if the signal was already processed before acting. This is the correct answer for most real systems because FIFO throughput limits are often unacceptable.
- **Deduplication ID** -- Standard queues can use a content-based hash. Not as strong as FIFO, but catches most duplicates.

### Visibility Timeout Misconfiguration

If your consumer takes 90 seconds to process a message but the visibility timeout is 60 seconds, the message becomes visible at second 60. Another consumer picks it up. Now two consumers are processing the same message simultaneously. This is a race condition.

**Rule:** Set visibility timeout to at least 6x your expected processing time. If processing takes 10 seconds, set timeout to 60. If processing takes 60 seconds, set timeout to 360.

Haven hit a version of this with SQLite: the `_is_signal_stale()` check took long enough on some signals that the next scheduler cycle picked up the same signal. The fix was date-based dedup. With SQS, the fix is visibility timeout tuning.

---

## The Result

After completing this module, you understand three AWS services that replace Haven's tight-coupling patterns:

| Haven Current | AWS Decoupled Equivalent |
|--------------|--------------------------|
| asyncio.Queue (volatile) | SQS Standard (durable, retries, DLQ) |
| SQLite INSERT/SELECT polling | SQS + SNS fan-out (decoupled, scalable) |
| Daemon `_scheduler_loop` | EventBridge cron rules (serverless, survives crashes) |
| Direct function calls between loops | SNS topics (producers don't know consumers) |

The Haven daemon works as-is. It processes 34 loops in a single process on a $15/month t3.small, and that is sufficient for its current scale. The decoupled architecture makes sense when:

- You need multiple independent consumers for the same events
- You need guaranteed message delivery across process boundaries
- You want scheduling that survives daemon restarts
- You are scaling beyond what a single SQLite file can handle

Understanding these services is not about rewriting Haven today. It is about knowing what tools exist when the architecture needs to evolve -- and about passing the SAA-C03, which tests decoupling patterns heavily.

---

## Key Takeaways

- **SQS Standard vs FIFO is the single most important comparison for the exam.** Standard = unlimited throughput, at-least-once, best-effort ordering. FIFO = 300/sec, exactly-once, strict ordering. Know which to use for each scenario.

- **Dead-letter queues catch poison messages.** Without a DLQ, a bad message is retried forever (or until retention expires). With a DLQ, it is retried N times and then moved aside for investigation. Always configure a DLQ in production.

- **SNS + SQS fan-out is a core AWS architecture pattern.** One message to an SNS topic fans out to multiple SQS queues. Each queue has its own consumer. Producers and consumers are fully decoupled.

- **EventBridge replaces CloudWatch Events and adds more.** If an exam question mentions "CloudWatch Events," treat it as EventBridge -- they are the same service. EventBridge adds third-party integrations and richer event patterns.

- **Long polling is always the right answer for SQS cost optimization.** `ReceiveMessageWaitTimeSeconds: 20` reduces empty API calls by orders of magnitude. Short polling is the default, which is unfortunate because it is almost never what you want.

- **Decoupling is an architectural principle, not a product.** SQS, SNS, and EventBridge are tools. The principle is: producers should not know about consumers, messages should survive failures, and adding new consumers should not require changing producers. The exam tests the principle through product-specific scenarios.

---

## Exam Lens

### Scenario Questions You Will See

**Q: An application processes financial transactions and must guarantee that each transaction is processed exactly once in the order it was received. Which SQS queue type should be used?**

A: **FIFO queue.** "Exactly once" + "in order" = FIFO. Standard queue cannot guarantee either. If the question adds "the system processes 500,000 transactions per second," the answer changes -- FIFO cannot handle that throughput, so you need Standard + idempotent consumers.

**Q: A company wants to send the same order notification to an inventory system, a shipping system, and an analytics system simultaneously. What is the most operationally efficient architecture?**

A: **SNS topic with three SQS queue subscriptions** (one per system). The order service publishes once to SNS. Each SQS queue receives a copy. Each system consumes from its own queue independently. This is the fan-out pattern.

**Q: An SQS consumer application is processing messages successfully but occasionally receives the same message twice, causing duplicate database entries. The system processes 100,000 messages per second. How should the architect solve this?**

A: **Implement idempotent processing in the consumer** (e.g., check for existing records before inserting). NOT FIFO -- the throughput requirement (100K/sec) exceeds FIFO limits (300/sec or 3,000 batched). This is an exam trap designed to see if you default to FIFO without checking throughput constraints.

**Q: A company wants to reduce SQS costs. Their consumers frequently poll empty queues. What should they change?**

A: **Enable long polling** (`ReceiveMessageWaitTimeSeconds` > 0, up to 20). Long polling waits for messages to arrive instead of returning empty responses immediately. Fewer API calls = lower cost.

**Q: A legacy application publishes events to Amazon SQS. A new microservice needs to receive the same events. The existing application code cannot be modified. What is the best approach?**

A: Add an **SNS topic** between the publisher and SQS. This requires a one-time change to the publisher (publish to SNS instead of SQS). Both the existing SQS queue and the new microservice's queue subscribe to the topic. If "cannot modify publisher" is absolute, use SQS message forwarding via Lambda.

**Q: An event-driven application needs to trigger a Lambda function every day at 8 AM UTC to generate a report. Which AWS service provides this scheduling capability with the LEAST operational overhead?**

A: **Amazon EventBridge** (scheduled rule with cron expression). Not CloudWatch Events (same service, older name, both are correct but EventBridge is the current answer). Not a cron job on EC2 (operational overhead of maintaining the instance).

**Q: An SQS message has been received and processed 5 times but the consumer keeps failing. The message should be preserved for later analysis rather than being retried indefinitely. What should the architect configure?**

A: A **dead-letter queue (DLQ)** with `maxReceiveCount: 5`. After 5 failed processing attempts, SQS automatically moves the message to the DLQ. Operations teams can then inspect the DLQ to diagnose the failure.

### Key Distinctions to Memorize

| Concept | Key Fact |
|---------|----------|
| SQS message retention | Default 4 days, max 14 days, min 1 minute |
| SQS message size | Max 256KB. Larger payloads: store in S3, send reference in SQS |
| SQS visibility timeout | Default 30 seconds, max 12 hours |
| SQS FIFO throughput | 300 msg/sec (3,000 with batching) per message group |
| SQS long polling max wait | 20 seconds |
| SNS message size | Max 256KB (same as SQS) |
| SNS subscribers per topic | 12.5 million (soft limit) |
| EventBridge rules per bus | 300 (soft limit) |
| EventBridge vs CloudWatch Events | Same service. EventBridge is the current name. |
| SQS delay queues | Postpone delivery of new messages 0-900 seconds |

---

Next: [Module 14 - Containers](../14-containers/) -- Dockerizing Haven for portable deployments.
