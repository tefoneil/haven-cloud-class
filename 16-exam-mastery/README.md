# Module 16: Exam Mastery

> **Maps to:** ALL SAA-C03 Domains | **Framework:** AWS Well-Architected
>
> **Type:** Conceptual (no build/teardown) | **Prerequisites:** All previous modules

---

## The Goal

You have built Haven's cloud infrastructure across 15 modules. You have deployed a VPC, launched an EC2 instance, configured systemd, set up S3 backups, wired CloudWatch alarms, stored secrets in SSM, hardened IAM, and built an operational dashboard. You understand how these services work because you have used them.

The SAA-C03 does not test whether you can use services. It tests whether you can choose the right service for a given scenario. Every question follows the same pattern: "A company needs X. Which solution meets the requirements with [least cost / highest availability / least operational overhead]?"

This module teaches you to think like the exam thinks.

---

## Part 1: Well-Architected Framework Applied to Haven

The AWS Well-Architected Framework defines five pillars of a good architecture. The exam tests all five, often in a single question. Here is how Haven maps to each pillar -- what we did right, what we would improve, and what the exam expects.

### Pillar 1: Operational Excellence

*"How do you run and monitor systems to deliver business value?"*

**What Haven does:**

| Practice | Implementation | Module |
|----------|---------------|--------|
| Perform operations as code | `systemd` unit file, `aws` CLI scripts | 03 |
| Make frequent, small changes | Git-based deployments, rsync | 02 |
| Anticipate failure | Heartbeat alarm, auto-restart on failure | 05 |
| Learn from operational events | CloudWatch dashboards, structured logs | 08 |

**What Haven would add at scale:**

- **AWS Systems Manager (SSM) Run Command**: Execute commands across a fleet without SSH. Haven has one instance, but the exam tests fleet management.
- **AWS CloudFormation / CDK**: Infrastructure as code. Haven's infrastructure was built with CLI commands. At scale, this should be a CloudFormation template so the entire stack can be reproduced in one command.
- **Runbooks and playbooks**: SSM Automation documents that codify incident response. "If heartbeat alarm fires, run this automation."

**Exam lens**: When a question mentions "operational overhead," they want managed services over self-managed. Lambda over EC2. RDS over self-hosted MySQL. Fargate over ECS on EC2. The fewer things you manage, the better your operational excellence score.

---

### Pillar 2: Security

*"How do you protect your information, systems, and assets?"*

**What Haven does:**

| Practice | Implementation | Module |
|----------|---------------|--------|
| Implement identity foundation | IAM least-privilege, separate user/role | 07 |
| Enable traceability | CloudTrail (default management events) | 07 |
| Apply security at all layers | SG + SSH keys + fail2ban + IAM | 07 |
| Protect data at rest | SSM SecureString (KMS), S3 encryption | 06 |
| Protect data in transit | HTTPS for all AWS API calls (SDK default) | -- |

**What Haven would add at scale:**

- **VPC private subnets**: Haven's daemon does not need a public IP. It could run in a private subnet with a NAT Gateway for outbound API calls. The public IP is only for SSH access, which could be replaced by SSM Session Manager (no SSH at all).
- **VPC endpoints**: Private connections to S3 and CloudWatch without traversing the internet. Reduces attack surface and can reduce NAT Gateway data transfer costs.
- **GuardDuty**: ML-based threat detection for $2-5/month.
- **MFA on IAM user**: The `HavenDev` IAM user should have MFA enabled.

**Exam lens**: Module 15 covers security services in depth. The key exam strategy: security is never optional. If a question offers a "cheaper but less secure" option, it is wrong unless the question explicitly says "security is not a concern" (which it never does).

---

### Pillar 3: Reliability

*"How do you ensure a workload performs its intended function correctly and consistently?"*

**What Haven does:**

| Practice | Implementation | Module |
|----------|---------------|--------|
| Automatically recover from failure | `Restart=always` in systemd | 03 |
| Test recovery procedures | S3 backup restore tested | 04 |
| Scale horizontally | Not applicable (single daemon) | -- |
| Stop guessing capacity | t3.small right-sized after monitoring | 01 |

**What Haven would add at scale:**

- **Multi-AZ deployment**: Haven runs in a single AZ (`us-east-1a`). If that AZ goes down, Haven goes down. A highly available version would run in multiple AZs behind an ALB.
- **RDS Multi-AZ**: If Haven moved to RDS, Multi-AZ provides a synchronous standby replica with automatic failover. The exam asks about this constantly.
- **S3 Cross-Region Replication**: Haven's backups are in one region. CRR copies objects to a bucket in another region for disaster recovery.
- **Route 53 failover routing**: Active-passive DNS failover to a standby instance in another region.

**Exam lens**: "Highly available" almost always means Multi-AZ. "Disaster recovery" almost always means multi-region. The exam uses four DR strategies with increasing cost and decreasing RTO:

| Strategy | Description | RTO | Cost |
|----------|-------------|-----|------|
| **Backup & Restore** | S3 backups, restore when needed (Haven today) | Hours | $ |
| **Pilot Light** | Core infrastructure running, scale up when needed | Minutes | $$ |
| **Warm Standby** | Scaled-down version running in secondary region | Minutes | $$$ |
| **Multi-Site Active/Active** | Full deployment in multiple regions | Seconds | $$$$ |

Haven uses Backup & Restore. The exam expects you to identify which strategy fits based on RTO/RPO requirements and cost constraints.

---

### Pillar 4: Performance Efficiency

*"How do you use computing resources efficiently?"*

**What Haven does:**

| Practice | Implementation | Module |
|----------|---------------|--------|
| Use the right resource type | t3.small for async I/O workload | 01 |
| Go serverless where possible | Not yet (but Lambda for backups would work) | -- |
| Experiment easily | EC2 instance type change takes 2 minutes | 01 |
| Mechanical sympathy | async Python + SQLite WAL mode | -- |

**Haven's performance profile:**

Haven is a 34-loop async Python daemon. It is I/O-bound, not CPU-bound. Most time is spent waiting for API responses (Helius, CoinGecko, Telegram). CPU spikes during signal scoring and LLM prompt construction, but these are brief. SQLite in WAL mode handles concurrent reads without blocking.

The t3.small (2 vCPU, 2 GB RAM) is right-sized. CPU averages 5-15% with spikes to 40% during scoring bursts. Memory sits at ~60%. Moving to a t3.micro would risk OOM during peak scoring. Moving to a t3.medium would waste money.

**Exam lens**: Instance type selection is a common question pattern. Know these families:

| Family | Optimized For | Example Use Case |
|--------|--------------|-----------------|
| **T** (burstable) | Variable workloads with occasional spikes | Haven, dev/test, small web apps |
| **M** (general purpose) | Balanced compute/memory | Application servers |
| **C** (compute) | CPU-intensive | Batch processing, video encoding, ML inference |
| **R** (memory) | Memory-intensive | In-memory databases, real-time analytics |
| **I** (storage) | High I/O | NoSQL databases, data warehousing |
| **G/P** (accelerated) | GPU workloads | ML training, graphics rendering |

The exam will describe a workload and ask which instance family fits. "High transaction database with large working set" = R-series. "Video transcoding pipeline" = C-series. "Variable traffic web application" = T-series.

---

### Pillar 5: Cost Optimization

*"How do you avoid unnecessary costs?"*

**What Haven does:**

| Practice | Implementation | Module |
|----------|---------------|--------|
| Implement cloud financial management | Track monthly spend (~$20/mo) | -- |
| Adopt a consumption model | Pay per use (EC2, S3, CloudWatch) | -- |
| Analyze and attribute expenditure | Single project, simple tracking | -- |
| Use managed services to reduce TCO | S3 over self-hosted backup, CloudWatch over self-hosted monitoring | 04, 05 |

**Haven's monthly cost breakdown:**

| Service | Cost | Notes |
|---------|------|-------|
| EC2 t3.small | ~$15.00 | On-demand pricing |
| EBS 20GB gp3 | ~$1.60 | |
| Elastic IP | $0.00 | Free when attached to running instance |
| S3 backups | ~$0.50 | ~20GB, lifecycle policy deletes old versions |
| CloudWatch | ~$1.00 | Custom metrics, dashboard (first 3 free) |
| NAT Gateway | $0.00 | Not deployed (public subnet) |
| **Total** | **~$18-20** | |

**How Haven could save more:**

- **Reserved Instance**: 1-year no-upfront RI for t3.small saves ~36% ($15 -> $9.60/month). 3-year all-upfront saves ~60%.
- **Savings Plans**: More flexible than RIs. Compute Savings Plan applies across instance families and regions.
- **Spot Instance**: Haven's daemon needs to run continuously, so Spot is not appropriate for the main workload. But a batch backtest job (run once, analyze results, terminate) is a perfect Spot candidate.

**EC2 pricing models -- the exam tests all of these:**

| Model | Commitment | Savings | Use Case |
|-------|-----------|---------|----------|
| **On-Demand** | None | 0% | Unpredictable workloads, short-term |
| **Reserved (Standard)** | 1 or 3 year | Up to 72% | Steady-state (Haven's daemon) |
| **Reserved (Convertible)** | 1 or 3 year | Up to 54% | Steady-state but may change instance type |
| **Savings Plans (Compute)** | 1 or 3 year | Up to 66% | Flexible across families, regions, OS |
| **Savings Plans (EC2 Instance)** | 1 or 3 year | Up to 72% | Locked to family + region, most savings |
| **Spot** | None | Up to 90% | Fault-tolerant, interruptible workloads |
| **Dedicated Hosts** | On-demand or reservation | Varies | Licensing requirements, compliance |

**Exam lens**: Cost optimization questions always have a "most cost-effective" qualifier. Key patterns:

- Steady state workload = Reserved Instance or Savings Plan
- Can tolerate interruptions = Spot Instance
- Mixed workload = Spot Fleet with On-Demand base capacity
- "Reduce cost immediately without commitment" = right-size instances, delete unused EBS volumes, S3 lifecycle policies
- Elastic IP attached to stopped instance = costs $0.005/hour. The exam loves this gotcha.

---

## Part 2: Service Decision Matrix

The exam tests "when to use X vs Y" for every major service pair. Here is the complete matrix, organized by category.

### Compute: Lambda vs EC2 vs Fargate

| Criteria | Lambda | EC2 | Fargate |
|----------|--------|-----|---------|
| **Runtime** | Max 15 minutes | Unlimited | Unlimited |
| **State** | Stateless | Stateful | Stateful (within task) |
| **Scaling** | Automatic (1000 concurrent default) | Manual or ASG | Automatic (service-level) |
| **Management** | Zero (no servers) | Full (OS, patching, scaling) | Partial (no servers, but task definitions) |
| **Cost at low volume** | Very cheap (per-invocation) | Expensive (always-on) | Moderate |
| **Cost at high volume** | Expensive | Cheap (reserved) | Moderate |
| **Haven fit** | Backup scripts, webhook handlers | Main daemon (current) | Daemon in container |

**Why Haven uses EC2**: The daemon runs 34 loops continuously. Lambda's 15-minute timeout and stateless model make it impossible to run a long-lived daemon. Fargate could work (Haven is already containerizable), but the added complexity of ECS task definitions and container registry management is not justified for a single instance.

**Exam triggers**: "Event-driven" or "runs for a few seconds" = Lambda. "Long-running process" or "needs OS access" = EC2. "Containerized without managing servers" = Fargate.

### Database: RDS vs DynamoDB vs Aurora

| Criteria | RDS | DynamoDB | Aurora |
|----------|-----|----------|--------|
| **Data model** | Relational (SQL) | Key-value / document (NoSQL) | Relational (MySQL/PostgreSQL compatible) |
| **Scaling** | Vertical (instance size) + read replicas | Horizontal (automatic) | Auto-scaling storage, read replicas |
| **Max storage** | 64 TB | Unlimited | 128 TB (auto-grows) |
| **Multi-AZ** | Synchronous standby (failover) | Built-in (3 AZ replication) | 6 copies across 3 AZs |
| **Serverless option** | No | Yes (on-demand capacity) | Yes (Aurora Serverless v2) |
| **Cost** | $$-$$$ | $ (on-demand) to $$$ (provisioned high throughput) | $$$ |
| **Haven fit** | If migrating from SQLite | Wallet tracking (high write, key-value) | Overkill for Haven's volume |

**Haven uses SQLite** because the data volume (233K messages, 31K signals) and access pattern (single writer, async reads) do not justify a managed database. If Haven needed multi-instance access or high availability, RDS PostgreSQL would be the natural migration target.

**Exam triggers**: "Relational data with complex queries" = RDS or Aurora. "Millisecond latency at any scale" = DynamoDB. "MySQL/PostgreSQL compatible with automatic scaling" = Aurora. "Serverless relational" = Aurora Serverless. "Key-value with automatic scaling" = DynamoDB.

### Messaging: SQS vs SNS vs EventBridge

| Criteria | SQS | SNS | EventBridge |
|----------|-----|-----|-------------|
| **Pattern** | Queue (pull) | Pub/sub (push) | Event bus (rules-based routing) |
| **Consumers** | One consumer per message (Standard) or message group (FIFO) | Multiple subscribers | Multiple targets via rules |
| **Ordering** | FIFO queue guarantees order | No ordering | No ordering (but can filter) |
| **Retry** | Built-in (visibility timeout) | Retry to HTTP endpoints | Retry with DLQ |
| **Use case** | Decouple producer/consumer, buffer spikes | Fan-out notifications | Event-driven routing, AWS service integration |

**Haven scenario**: If Haven's daemon needed to decouple signal scoring from trade execution, SQS would sit between them. The scorer pushes scored alerts to a queue. The executor polls the queue and processes trades. If the executor falls behind, messages accumulate in the queue instead of being dropped.

For fan-out: if a new alert needs to trigger both a Telegram notification AND a paper trade AND an outcome tracker, SNS would publish once and deliver to three SQS queue subscribers.

**Exam triggers**: "Decouple" or "buffer" = SQS. "Fan-out" or "multiple subscribers" = SNS. "Route events based on content" or "AWS service events" = EventBridge. "Guaranteed ordering" = SQS FIFO.

### Load Balancing: ALB vs NLB

| Criteria | ALB | NLB |
|----------|-----|-----|
| **Layer** | 7 (HTTP/HTTPS) | 4 (TCP/UDP/TLS) |
| **Routing** | Path, host, header, query string | Port-based only |
| **WebSocket** | Yes | Yes (TCP passthrough) |
| **Static IP** | No (use Global Accelerator for static) | Yes |
| **Performance** | Millions of requests/sec | Ultra-low latency, millions of connections/sec |
| **Health checks** | HTTP/HTTPS | TCP, HTTP, HTTPS |
| **WAF integration** | Yes | No |
| **Haven fit** | Future API/webhook endpoint | Not needed |

**Exam triggers**: "HTTP routing" or "path-based routing" or "microservices" = ALB. "Ultra-low latency" or "static IP" or "TCP/UDP protocol" = NLB. "WebSocket" = either works, but ALB if HTTP is also needed. "WAF" = must be ALB.

### Storage: S3 vs EBS vs EFS

| Criteria | S3 | EBS | EFS |
|----------|-----|-----|-----|
| **Type** | Object storage | Block storage | File storage (NFS) |
| **Access** | HTTP API | Attached to one EC2 instance | Mounted by multiple instances |
| **Durability** | 11 9s (99.999999999%) | 99.999% | 11 9s |
| **Performance** | Throughput-optimized | IOPS-optimized (gp3, io2) | Throughput-optimized |
| **Cost (per GB)** | $0.023 (Standard) | $0.08 (gp3) | $0.30 (Standard) |
| **Use case** | Backups, static assets, data lake | OS disk, databases | Shared file system across instances |

**Haven uses**: EBS (gp3) for the OS and database. S3 for backups.

**S3 storage classes** (exam favorite):

| Class | Access Pattern | Cost | Retrieval |
|-------|---------------|------|-----------|
| **Standard** | Frequent | $$$ | Instant |
| **Standard-IA** | Infrequent (30-day min) | $$ | Instant, per-GB retrieval fee |
| **One Zone-IA** | Infrequent, non-critical | $ | Instant, single AZ |
| **Glacier Instant Retrieval** | Archive, quarterly access | $ | Instant |
| **Glacier Flexible Retrieval** | Archive, annual access | $ | Minutes to hours |
| **Glacier Deep Archive** | Long-term archive | ¢ | 12-48 hours |
| **Intelligent-Tiering** | Unknown/changing patterns | Auto-optimized | Instant |

**Exam triggers**: "Unknown access pattern" = Intelligent-Tiering. "Archive with instant access" = Glacier Instant Retrieval. "Cheapest archive" = Glacier Deep Archive. "Shared across instances" = EFS. "Database storage" = EBS.

### DNS: Route 53 Routing Policies

| Policy | How It Works | Use Case |
|--------|-------------|----------|
| **Simple** | One record, one or more values (random if multiple) | Single resource |
| **Weighted** | Distribute traffic by percentage | A/B testing, gradual migration |
| **Latency** | Route to lowest-latency region | Global applications |
| **Failover** | Active-passive with health checks | Disaster recovery |
| **Geolocation** | Route by user's geographic location | Content localization, compliance |
| **Geoproximity** | Route by geographic proximity with bias | Shift traffic between regions |
| **Multivalue answer** | Up to 8 healthy records returned | Simple load balancing with health checks |

**Exam triggers**: "Active-passive" or "disaster recovery" = Failover. "Route users to closest region" = Latency. "Regulatory requirement to keep data in user's country" = Geolocation. "Gradual migration" = Weighted.

### Content Delivery: CloudFront vs Global Accelerator

| Criteria | CloudFront | Global Accelerator |
|----------|-----------|-------------------|
| **Type** | CDN (caches content at edge) | Network accelerator (routes to optimal endpoint) |
| **Caching** | Yes | No |
| **Static content** | Excellent | Not designed for this |
| **Dynamic content** | Good (with cache behaviors) | Excellent |
| **Static IP** | No (use Lambda@Edge for IP-based logic) | Yes (2 anycast IPs) |
| **Protocol** | HTTP/HTTPS | TCP/UDP |
| **Use case** | Web content, API caching, S3 origin | Gaming, IoT, non-HTTP, multi-region ALB |

**Exam triggers**: "Cache static content" or "reduce latency for web content" = CloudFront. "Static IP addresses" or "TCP/UDP acceleration" = Global Accelerator. "Both static and dynamic content with edge caching" = CloudFront.

### Secrets: Secrets Manager vs SSM Parameter Store

Covered in Module 15. Quick decision:

- **Needs automatic rotation?** Secrets Manager.
- **RDS database password?** Secrets Manager.
- **Just storing a value (config or secret)?** SSM Parameter Store.
- **Cross-account sharing?** Secrets Manager.
- **Cost matters and rotation is not needed?** SSM Parameter Store.

### Encryption: KMS Key Types

Covered in Module 15. Quick decision:

- **Default encryption, no control needed?** AWS owned key.
- **Need to see the key in KMS console?** AWS managed key.
- **Need cross-account access, custom policies, or manual rotation schedule?** Customer managed key (CMK).
- **Regulatory requirement to import your own key material?** CMK with imported key material.

---

## Part 3: 20 Scenario-Based Practice Questions

These questions match SAA-C03 difficulty and format. Each question has one correct answer and three plausible distractors. Explanations cover why each wrong answer is wrong.

---

### Question 1 (Security)

A cryptocurrency analytics platform stores trading signals in an RDS PostgreSQL database. The security team requires that the database credentials be rotated every 30 days without any application downtime. The credentials are currently stored in environment variables on the EC2 instances.

What should the solutions architect do?

**A.** Store the credentials in AWS Secrets Manager with automatic rotation enabled. Configure the application to retrieve credentials from Secrets Manager at connection time.

**B.** Store the credentials in SSM Parameter Store as SecureString. Create a CloudWatch Events rule that triggers a Lambda function every 30 days to update the parameter.

**C.** Store the credentials in an encrypted S3 object. Use S3 Object Lock to prevent modification and rotate manually every 30 days.

**D.** Enable IAM database authentication for RDS. Assign an IAM role to the EC2 instances with `rds-db:connect` permission.

<details>
<summary>Answer</summary>

**A.** Secrets Manager has native RDS integration for automatic credential rotation. It handles both updating the password in RDS and making the new password available to applications without downtime. The rotation Lambda function is provided by AWS.

**B is wrong**: SSM Parameter Store does not have automatic rotation. You would need to build and maintain the rotation logic yourself in a Lambda function, including coordinating the RDS password change with the parameter update. This works but is not "automatic rotation" -- it is custom-built rotation.

**C is wrong**: S3 is not a secrets management service. Object Lock prevents deletion, not modification tracking. Manual rotation does not meet the "without downtime" requirement.

**D is partially right**: IAM database authentication eliminates passwords entirely, which is even better than rotation. However, it requires application code changes to generate authentication tokens and has limitations (max 256 connections/second with IAM auth on RDS). This is a valid architecture but does not directly answer "rotate credentials every 30 days" -- it sidesteps the requirement. On the exam, when the question specifically says "rotate credentials," the answer is Secrets Manager.
</details>

---

### Question 2 (Resilience)

A company runs a market data processing application on a single EC2 instance in us-east-1a. The application uses a local SQLite database stored on the instance's EBS volume. The business requires the application to recover within 4 hours if the Availability Zone becomes unavailable. Daily database backups are stored in S3.

What is the MOST cost-effective solution?

**A.** Create an AMI of the instance. When the AZ fails, launch a new instance from the AMI in a different AZ and restore the database from S3.

**B.** Deploy a second EC2 instance in us-east-1b running a hot standby. Use Route 53 failover routing to switch traffic.

**C.** Migrate the database to RDS Multi-AZ. Deploy the application in an Auto Scaling group across two AZs.

**D.** Use AWS Elastic Disaster Recovery (DRS) to continuously replicate the instance to another AZ.

<details>
<summary>Answer</summary>

**A.** This is the Backup & Restore DR strategy. The 4-hour RTO is generous enough that spinning up a new instance from an AMI and restoring the DB from S3 is feasible. Creating an AMI is essentially free (just S3 storage for the snapshot). This matches Haven's actual architecture.

**B is wrong**: A hot standby works but is not "most cost-effective." Running a second instance 24/7 doubles the EC2 cost when the requirement only needs 4-hour recovery, not instant failover.

**C is wrong**: RDS Multi-AZ and an ASG would provide near-zero downtime, but the question asks for "most cost-effective" with a 4-hour RTO. Migrating from SQLite to RDS and adding an ASG is significant cost and complexity for a 4-hour requirement.

**D is wrong**: AWS DRS provides continuous replication with sub-second RPO. This is more capability (and cost) than a 4-hour RTO requires.
</details>

---

### Question 3 (Security)

An application running on EC2 instances in a private subnet needs to access an S3 bucket without sending traffic over the internet. The security team also requires that S3 access be restricted to only this VPC.

What combination of actions should the architect take? (Select TWO.)

**A.** Create an S3 gateway endpoint in the VPC and update the route tables for the private subnet.

**B.** Create an S3 interface endpoint (PrivateLink) in the VPC and configure a security group.

**C.** Add a bucket policy with a condition that restricts access to the VPC endpoint using `aws:sourceVpce`.

**D.** Add a bucket policy that allows access from the VPC's CIDR range using `aws:SourceIp`.

**E.** Configure a NAT Gateway in a public subnet and route S3 traffic through it.

<details>
<summary>Answer</summary>

**A and C.** The S3 gateway endpoint provides private connectivity from the VPC to S3 without traversing the internet. It is free (no hourly charge, no data processing charge). The bucket policy with `aws:sourceVpce` restricts the bucket to only accept requests from that specific VPC endpoint.

**B is wrong**: S3 interface endpoints (PrivateLink) exist but cost $0.01/hour + data processing fees. Gateway endpoints are free and recommended for S3 and DynamoDB. The exam expects you to choose the gateway endpoint for S3.

**D is wrong**: Private subnet instances use private IPs. `aws:SourceIp` checks the public IP of the request source. Traffic through a VPC endpoint does not have a public IP, so this condition would not work as expected.

**E is wrong**: A NAT Gateway would allow S3 access but sends traffic over the internet (through the NAT, to the S3 public endpoint). The requirement says "without sending traffic over the internet."
</details>

---

### Question 4 (Performance)

A real-time analytics application processes 50,000 events per second. Events arrive via an API Gateway endpoint and must be stored for analysis. The events are small (1 KB each) and queries are simple key-value lookups by event ID. The team needs single-digit millisecond read latency.

Which database solution meets these requirements?

**A.** Amazon Aurora PostgreSQL with read replicas

**B.** Amazon DynamoDB with provisioned capacity

**C.** Amazon RDS MySQL with Multi-AZ deployment

**D.** Amazon ElastiCache for Redis

<details>
<summary>Answer</summary>

**B.** DynamoDB is designed for exactly this use case: high-throughput key-value lookups with single-digit millisecond latency at any scale. Provisioned capacity handles the predictable 50K events/second rate. DynamoDB can also use on-demand capacity to handle spikes.

**A is wrong**: Aurora is excellent for relational workloads but is not optimized for simple key-value lookups at 50K/second. It could handle it, but it is over-engineered for key-value access patterns.

**C is wrong**: RDS MySQL at 50K writes/second would require a very large instance and would struggle with consistent single-digit millisecond reads under that write load.

**D is wrong**: ElastiCache provides sub-millisecond latency (even faster than DynamoDB), but it is an in-memory cache, not a primary database. If the instance fails, data is lost unless backed by another data store. The question says "must be stored," implying durable storage.
</details>

---

### Question 5 (Cost)

A company runs batch processing jobs that take 2-6 hours to complete. The jobs process market data and can be restarted from the beginning if interrupted. The jobs currently run on On-Demand EC2 instances and cost $3,400/month.

What change would reduce costs the most?

**A.** Purchase 1-year Standard Reserved Instances for the batch processing instances.

**B.** Use Spot Instances with checkpointing and a Spot Instance interruption handler.

**C.** Migrate the batch processing to AWS Lambda functions.

**D.** Use a Compute Savings Plan for the batch processing instances.

<details>
<summary>Answer</summary>

**B.** Spot Instances provide up to 90% savings over On-Demand. The workload is explicitly described as interruptible ("can be restarted from the beginning"), which is the key qualifier for Spot. This would reduce the $3,400 bill to ~$340-680.

**A is wrong**: Reserved Instances save up to 72% but require a 1-year commitment. Spot saves up to 90%. For fault-tolerant batch workloads, Spot is always more cost-effective.

**C is wrong**: Lambda has a 15-minute maximum execution time. Jobs that run 2-6 hours cannot run on Lambda without fundamental re-architecture into many small functions.

**D is wrong**: Savings Plans save up to 66% (Compute) or 72% (EC2 Instance). Both are less than Spot's up to 90%, and both require a 1 or 3-year commitment. For interruptible batch jobs, Spot wins on cost.
</details>

---

### Question 6 (Security)

A solutions architect discovers that an EC2 instance in a public subnet is accepting SSH connections from any IP address (0.0.0.0/0). The security team wants to be automatically notified whenever a security group rule allows SSH from 0.0.0.0/0 and have the rule automatically remediated.

Which combination of services achieves this?

**A.** GuardDuty to detect the misconfiguration, SNS to send notifications

**B.** AWS Config rule (`restricted-ssh`) with auto-remediation via SSM Automation, and SNS for notifications

**C.** CloudTrail to log the security group change, CloudWatch Events to trigger Lambda for remediation

**D.** VPC Flow Logs to detect SSH traffic from unauthorized IPs, Lambda to modify the security group

<details>
<summary>Answer</summary>

**B.** AWS Config has a managed rule called `restricted-ssh` that evaluates security groups for unrestricted SSH access. When non-compliant, Config can trigger SSM Automation to automatically remove the offending rule (auto-remediation). SNS handles the notification. This is the purpose-built solution.

**A is wrong**: GuardDuty detects threats (like unauthorized access attempts), not configuration issues. An open security group is a misconfiguration, not a threat. The right tool for configuration compliance is AWS Config.

**C is wrong**: This would work (CloudTrail logs `AuthorizeSecurityGroupIngress`, CloudWatch Events triggers Lambda to revert), but it is a custom-built solution. AWS Config provides this as a managed capability with less operational overhead. The exam prefers managed solutions.

**D is wrong**: VPC Flow Logs show accepted/rejected traffic but do not show security group rule definitions. You would not know from flow logs alone whether a rule allows 0.0.0.0/0 -- you would only see that traffic from various IPs was accepted.
</details>

---

### Question 7 (Resilience)

An application uses an Auto Scaling group with instances in us-east-1a and us-east-1b. The ASG has min=2, max=6, desired=4. Currently, 2 instances run in each AZ. If us-east-1a experiences an outage, what happens?

**A.** The ASG launches 2 new instances in us-east-1b, resulting in 4 instances in us-east-1b.

**B.** The ASG reduces the desired capacity to 2, running both instances in us-east-1b.

**C.** The ASG launches instances in us-east-1c automatically.

**D.** The application goes offline until us-east-1a recovers.

<details>
<summary>Answer</summary>

**A.** Auto Scaling groups maintain the desired capacity. When 2 instances in us-east-1a become unhealthy/unavailable, the ASG launches 2 replacement instances. Since us-east-1a is unavailable, the replacements launch in us-east-1b, resulting in 4 instances in us-east-1b. The desired count of 4 is maintained.

**B is wrong**: The ASG does not reduce desired capacity due to an AZ outage. It tries to maintain the desired count.

**C is wrong**: The ASG only uses AZs that were configured. If only us-east-1a and us-east-1b were specified, it will not automatically use us-east-1c.

**D is wrong**: The ASG is specifically designed to handle AZ failures by rebalancing across remaining AZs.
</details>

---

### Question 8 (Performance)

A company needs to serve a mix of static assets (images, CSS, JavaScript) and dynamic API responses to users worldwide. Static content changes rarely. API responses are personalized and cannot be cached. Both must be served from a single domain name.

Which solution provides the best performance?

**A.** CloudFront distribution with two origins: S3 for static content and ALB for the API. Use path-based cache behaviors (/api/* forwards to ALB with caching disabled, /* serves from S3 cache).

**B.** S3 static website hosting with Route 53 latency-based routing for the API across multiple regions.

**C.** Global Accelerator with an ALB origin serving both static and dynamic content.

**D.** CloudFront with a single ALB origin for all content. Set Cache-Control headers to differentiate static and dynamic.

<details>
<summary>Answer</summary>

**A.** CloudFront with multiple origins and cache behaviors is the purpose-built solution. Static content is cached at edge locations worldwide (low latency, reduced origin load). API requests are forwarded to the ALB with caching disabled (`CachingDisabled` managed policy). Path-based routing (/api/* vs /*) handles the routing. Single domain, single CloudFront distribution.

**B is wrong**: S3 static website hosting does not integrate with Route 53 latency routing for a unified domain. You would need separate subdomains for static and API, which violates the "single domain name" requirement.

**C is wrong**: Global Accelerator does not cache content. It accelerates TCP/UDP connections to your endpoints. Without caching, every static asset request hits the origin, which defeats the purpose for rarely-changing content.

**D is wrong**: A single ALB origin means static content is served by the ALB instead of directly from S3. This adds unnecessary load on the ALB and costs more. The ALB also needs to serve static files, requiring the application to handle asset delivery.
</details>

---

### Question 9 (Cost)

A startup stores application logs in S3. Logs are analyzed daily for the first week, then accessed roughly once per month for 3 months, then must be retained for 7 years for compliance but are almost never accessed.

What is the MOST cost-effective S3 storage strategy?

**A.** Store all logs in S3 Standard. Manually move to Glacier after 3 months.

**B.** Create a lifecycle policy: Standard for 7 days, Standard-IA for 90 days, Glacier Deep Archive after that.

**C.** Use S3 Intelligent-Tiering for all logs.

**D.** Store all logs in S3 One Zone-IA from day one.

<details>
<summary>Answer</summary>

**B.** Lifecycle policies automate tier transitions based on object age. Standard handles the frequent daily access (week 1). Standard-IA handles the infrequent monthly access (months 1-3) at lower cost. Glacier Deep Archive handles the 7-year compliance retention at the lowest possible cost ($0.00099/GB/month). This is fully automated.

**A is wrong**: Manual transitions do not scale and are error-prone. S3 Standard for the full first 3 months costs more than transitioning to Standard-IA after 7 days.

**C is wrong**: Intelligent-Tiering adds a monitoring fee per object ($0.0025 per 1,000 objects/month). For logs with a known, predictable access pattern, a lifecycle policy is cheaper because you already know when access patterns change.

**D is wrong**: One Zone-IA stores data in a single AZ. Compliance data that must be retained for 7 years should not risk a full AZ loss. Also, daily access in the first week would incur retrieval fees on every IA access.
</details>

---

### Question 10 (Security)

An application runs on EC2 instances in a private subnet. The instances need to download software updates from the internet but must not be directly accessible from the internet.

Which solution allows outbound internet access without inbound exposure?

**A.** Attach an Elastic IP to each instance and use security groups to block inbound traffic.

**B.** Deploy a NAT Gateway in a public subnet. Update private subnet route tables to route 0.0.0.0/0 through the NAT Gateway.

**C.** Create a VPC endpoint for the software update repository.

**D.** Deploy an internet gateway and add a route in the private subnet's route table.

<details>
<summary>Answer</summary>

**B.** A NAT Gateway in a public subnet enables outbound internet access for private subnet instances. The NAT Gateway handles address translation -- instances initiate outbound connections, but no inbound connections from the internet can reach the instances. This is the standard pattern.

**A is wrong**: An Elastic IP makes the instance publicly reachable. Even with security groups blocking inbound, the instance has a public IP, which violates "must not be directly accessible from the internet."

**C is wrong**: VPC endpoints provide private access to AWS services (S3, DynamoDB, etc.), not to arbitrary internet software repositories. Unless the updates are hosted on an AWS service with a VPC endpoint, this does not work.

**D is wrong**: Adding an internet gateway route (0.0.0.0/0 -> igw) to a private subnet's route table makes it a public subnet by definition. Instances with public IPs would be directly reachable. This is the opposite of what is needed.
</details>

---

### Question 11 (Resilience)

A company hosts a web application on EC2 behind an ALB. The application uses RDS MySQL. The current architecture is single-AZ. The CTO requires the application to survive an AZ failure with no more than 60 seconds of database downtime.

What changes are needed?

**A.** Enable RDS Multi-AZ. Add instances in a second AZ to the ALB target group.

**B.** Create an RDS read replica in a second AZ. Use Route 53 failover routing.

**C.** Take RDS automated snapshots every minute. Restore in another AZ if failure occurs.

**D.** Migrate to Aurora with Multi-AZ cluster deployment. Deploy EC2 in two AZs behind the ALB.

<details>
<summary>Answer</summary>

**A.** RDS Multi-AZ creates a synchronous standby replica in another AZ. On failure, RDS automatically fails over to the standby, typically within 60-120 seconds. The DNS name stays the same -- no application changes needed. Adding EC2 instances in a second AZ ensures the compute tier also survives an AZ failure.

**B is wrong**: Read replicas are asynchronous and designed for read scaling, not failover. Promoting a read replica requires manual intervention or custom automation, the connection endpoint changes, and there may be data lag. Not designed for the "60 seconds of downtime" requirement.

**C is wrong**: Restoring from a snapshot takes minutes to hours depending on database size, not 60 seconds. Snapshots have an RPO of up to 5 minutes (automated backup interval), meaning you could lose 5 minutes of data.

**D is wrong**: Aurora Multi-AZ is more capable (6 copies, 3 AZs, 15-second failover), but the question asks what changes are "needed" for 60-second failover. Standard RDS Multi-AZ meets the 60-second requirement at lower cost. Aurora is overkill here.
</details>

---

### Question 12 (Performance)

A data processing pipeline ingests 100 GB of CSV files daily, transforms the data, and loads it into a data warehouse. The transformation takes 3 hours on a c5.4xlarge instance. The files arrive at 2 AM and the results must be ready by 8 AM. The company wants to minimize costs.

Which approach is most cost-effective?

**A.** Run the transformation on a Reserved c5.4xlarge instance.

**B.** Run the transformation on a Spot c5.4xlarge instance with a Spot interruption handler that checkpoints progress.

**C.** Run the transformation on AWS Lambda with Step Functions orchestrating the pipeline.

**D.** Run the transformation on an On-Demand c5.4xlarge instance.

<details>
<summary>Answer</summary>

**B.** The workload runs for 3 hours once daily (3/24 = 12.5% utilization). A Reserved Instance would be paid for 24 hours but used for 3 -- wasteful. Spot provides up to 90% savings. The 6-hour window (2 AM to 8 AM) gives 3 hours of slack if the Spot instance is interrupted and the job needs to restart. Checkpointing reduces re-processing if interrupted.

**A is wrong**: A Reserved Instance costs the same whether used 3 hours or 24 hours per day. At 12.5% utilization, you are paying for 87.5% idle time. Reserved makes sense for always-on workloads, not batch jobs.

**C is wrong**: 100 GB of CSV transformation for 3 hours cannot run on Lambda. Each Lambda invocation is limited to 15 minutes and 10 GB ephemeral storage. You would need complex orchestration to split the work, and the aggregate Lambda cost for 3 hours of c5.4xlarge-equivalent compute would likely exceed Spot pricing.

**D is wrong**: On-Demand costs more than Spot by up to 90%. For an interruptible batch job with a time buffer, Spot is always preferred over On-Demand.
</details>

---

### Question 13 (Security)

A company's CloudTrail logs show that an IAM user's access keys are being used from an IP address in a country where the company has no operations. The keys have `AdministratorAccess`. What should the architect do FIRST?

**A.** Delete the IAM user.

**B.** Deactivate the access keys and investigate using CloudTrail.

**C.** Add an IP restriction to the IAM policy.

**D.** Enable MFA on the IAM user.

<details>
<summary>Answer</summary>

**B.** Deactivating the access keys immediately stops the unauthorized access without destroying audit evidence. Deleting the user (A) would also stop access but removes the user's policy and activity history, making investigation harder. IP restriction (C) does not stop an attacker who may use a VPN. MFA (D) does not help with access keys (MFA can be required for console login or API calls, but the keys are already compromised). The word "FIRST" is key -- stop the bleeding, then investigate.

**A is wrong**: Deleting the user is too aggressive for a first step. You lose the ability to investigate what policies were attached, what actions were taken under that identity, and when the compromise started.

**C is wrong**: IP conditions can be bypassed with VPNs or proxies. Also, adding a policy condition does not stop in-progress abuse.

**D is wrong**: MFA protects future authentication but does not revoke currently compromised access keys. The keys work without MFA unless the IAM policy explicitly requires `aws:MultiFactorAuthPresent`.
</details>

---

### Question 14 (Resilience)

A global e-commerce platform needs its primary database in us-east-1 but requires read access from eu-west-1 with less than 20ms read latency for European users.

Which database solution meets this requirement?

**A.** RDS MySQL with a cross-region read replica in eu-west-1

**B.** DynamoDB Global Tables with a replica in eu-west-1

**C.** Aurora Global Database with a secondary cluster in eu-west-1

**D.** ElastiCache for Redis Global Datastore with a replica in eu-west-1

<details>
<summary>Answer</summary>

**C.** Aurora Global Database provides cross-region read replicas with less than 1 second replication lag. Reads from the secondary cluster in eu-west-1 are local, achieving single-digit millisecond latency. The primary cluster in us-east-1 handles all writes. This is designed exactly for this use case.

**A is wrong**: RDS cross-region read replicas have higher replication lag (minutes, not seconds) and the replica is a standalone instance, not a local cluster. Latency could meet 20ms for reads since the replica is in eu-west-1, but Aurora Global Database provides better replication and is the preferred solution for this pattern.

**B is wrong**: DynamoDB Global Tables provide multi-region active-active replication with single-digit millisecond reads. This technically works, but the question implies a relational database ("primary database" with "read access"). If the application uses SQL, DynamoDB requires a full rewrite. The exam expects you to match the database type to the workload.

**D is wrong**: ElastiCache is a cache layer, not a primary database. It can reduce read latency but depends on a backing data store. The question asks for a database solution.
</details>

---

### Question 15 (Cost)

A company has 200 EC2 instances running across multiple instance families (m5, c5, r5) in three regions. They want to reduce costs with a commitment-based pricing model but need the flexibility to change instance families and regions over the 3-year term.

Which option provides the best savings with this flexibility?

**A.** Standard Reserved Instances for each instance family in each region

**B.** Convertible Reserved Instances

**C.** Compute Savings Plan

**D.** EC2 Instance Savings Plan

<details>
<summary>Answer</summary>

**C.** Compute Savings Plans provide savings (up to 66%) on any EC2 instance regardless of family, size, OS, tenancy, or region. They also apply to Fargate and Lambda. This matches the requirement for cross-family, cross-region flexibility.

**A is wrong**: Standard RIs are locked to a specific instance family, size, and region. To cover m5, c5, and r5 across three regions, you would need 9+ separate RI purchases. No flexibility to change after purchase.

**B is wrong**: Convertible RIs can be exchanged for different instance types, but only for an equal or greater value. Exchanges are manual and require matching remaining terms. This is more flexible than Standard RIs but less flexible than Savings Plans.

**D is wrong**: EC2 Instance Savings Plans are locked to a specific instance family in a specific region. They offer higher savings than Compute Savings Plans (up to 72%) but do not provide cross-family or cross-region flexibility.
</details>

---

### Question 16 (Performance)

An application needs to process messages from an SQS queue. Each message takes 5 minutes to process. During peak hours, 1,000 messages arrive per minute. During off-peak, 10 messages arrive per minute. The processing is CPU-intensive.

What architecture handles this efficiently?

**A.** A single large EC2 instance polling the queue continuously.

**B.** An Auto Scaling group of EC2 instances scaling based on the `ApproximateNumberOfMessagesVisible` CloudWatch metric.

**C.** Lambda functions triggered by the SQS queue.

**D.** An ECS Fargate service with task auto-scaling based on queue depth.

<details>
<summary>Answer</summary>

**B.** Auto Scaling based on queue depth handles the 100x traffic variation (10 to 1,000 messages/minute). At peak, the ASG scales out to process the queue. At off-peak, it scales in. SQS handles the buffering during scaling events. The `ApproximateNumberOfMessagesVisible` metric directly reflects the backlog.

**C is wrong**: Each message takes 5 minutes. Lambda's maximum timeout is 15 minutes, so it technically fits. However, 1,000 concurrent Lambda invocations running for 5 minutes each would be extremely expensive (5,000 Lambda-minutes per peak minute). Also, "CPU-intensive" workloads are better served by dedicated compute instances where you control the instance type, rather than Lambda's shared compute environment.

**A is wrong**: A single instance cannot process 1,000 messages/minute when each takes 5 minutes. You would need 5,000 concurrent processing threads on a single instance, which is impractical for CPU-intensive work.

**D is wrong**: Fargate could work, but ECS Fargate auto-scaling based on custom queue depth metrics requires more setup (custom CloudWatch metrics, Application Auto Scaling policies) compared to EC2 ASG scaling policies. The exam prefers simpler solutions.
</details>

---

### Question 17 (Security)

A web application is deployed behind an ALB. The security team has identified that the application is vulnerable to SQL injection attacks. They need protection with the LEAST operational overhead.

**A.** Deploy a reverse proxy EC2 instance running ModSecurity in front of the ALB.

**B.** Enable AWS WAF with the `AWSManagedRulesCommonRuleSet` on the ALB.

**C.** Add input validation Lambda functions behind the ALB using Lambda target groups.

**D.** Configure the ALB to inspect request bodies and drop requests containing SQL keywords.

<details>
<summary>Answer</summary>

**B.** AWS WAF with managed rule groups provides SQL injection protection with zero custom code and minimal operational overhead. The `AWSManagedRulesCommonRuleSet` includes SQL injection rules maintained by AWS. Attach the Web ACL to the ALB and it is active.

**A is wrong**: Running a reverse proxy on EC2 requires managing an instance (OS patching, scaling, monitoring, high availability). This is the opposite of "least operational overhead."

**C is wrong**: Custom Lambda functions for input validation require writing and maintaining code, handling edge cases, and scaling. Far more operational overhead than a managed WAF rule group.

**D is wrong**: ALBs cannot inspect request bodies for SQL keywords. ALBs route traffic based on HTTP attributes (path, host, headers) but do not perform deep content inspection. That is WAF's job.
</details>

---

### Question 18 (Resilience)

A company hosts a critical application on EC2 instances behind an ALB in us-east-1. They need a disaster recovery solution in us-west-2 with an RTO of 15 minutes and an RPO of 1 minute.

Which DR strategy meets these requirements at the LOWEST cost?

**A.** Multi-Site Active/Active: Full deployment in both regions with Route 53 latency routing.

**B.** Warm Standby: Scaled-down infrastructure in us-west-2 that can scale up in minutes.

**C.** Pilot Light: AMIs and database snapshots in us-west-2, launch infrastructure on failure.

**D.** Backup & Restore: S3 cross-region replication of backups, restore from scratch on failure.

<details>
<summary>Answer</summary>

**B.** Warm Standby runs a scaled-down version of the full environment in the DR region. On failover, you scale up the instances (takes minutes, within the 15-minute RTO). With continuous database replication (RDS cross-region replica or similar), RPO is under 1 minute. This is the lowest-cost option that meets both the 15-minute RTO and 1-minute RPO.

**A is wrong**: Active/Active meets the requirements but is not the lowest cost. Running full production capacity in two regions is roughly double the cost. The question asks for "lowest cost."

**C is wrong**: Pilot Light keeps only core components running (like a database replica). Launching EC2 instances, configuring load balancers, and deploying code from scratch typically takes 30-60 minutes, exceeding the 15-minute RTO.

**D is wrong**: Backup & Restore from S3 takes hours (recreating infrastructure, restoring databases from snapshots). This cannot meet a 15-minute RTO or 1-minute RPO.
</details>

---

### Question 19 (Cost)

A data analytics team runs queries against 5 TB of JSON data stored in S3. Queries run 3-4 times per day and each query scans the entire dataset. The team uses Amazon Athena. The monthly Athena cost is $750 (5 TB x 4 queries/day x 30 days x $5/TB scanned).

What is the MOST effective way to reduce costs?

**A.** Convert the JSON files to Apache Parquet format and use columnar queries.

**B.** Move the data from S3 Standard to S3 Intelligent-Tiering.

**C.** Replace Athena with an EMR cluster running Hive queries.

**D.** Enable S3 Transfer Acceleration for faster query performance.

<details>
<summary>Answer</summary>

**A.** Parquet is a columnar format. When queries only need specific columns (which is almost always the case), Athena only scans the relevant columns instead of the entire row. Parquet also compresses much better than JSON. Converting 5 TB of JSON to Parquet typically reduces data to ~500 GB-1 TB (5-10x compression), and columnar scanning means only 10-30% of that is actually read per query. Athena cost could drop from $750/month to $15-75/month.

**B is wrong**: Storage class affects storage cost, not query cost. Athena charges per TB scanned regardless of which S3 tier the data is in. The $750 bill is query cost, not storage cost.

**C is wrong**: An EMR cluster running 24/7 to serve 3-4 queries/day would cost significantly more than $750/month. EMR makes sense for continuous processing, not sporadic queries.

**D is wrong**: Transfer Acceleration speeds up uploads to S3. It does not affect Athena query performance or cost. Athena reads directly from S3 within the same region -- network speed is not the bottleneck.
</details>

---

### Question 20 (Security)

A company wants to enforce that ALL new S3 buckets created in their account are encrypted with SSE-KMS using a specific customer managed key. They also want to prevent anyone from creating unencrypted buckets.

Which approach enforces this requirement?

**A.** Enable S3 default encryption at the account level with the CMK.

**B.** Create a Service Control Policy (SCP) that denies `s3:CreateBucket` unless the `s3:x-amz-server-side-encryption` condition specifies the CMK ARN.

**C.** Use AWS Config rule `s3-bucket-server-side-encryption-enabled` with auto-remediation.

**D.** Create an IAM policy attached to all users that denies `s3:PutObject` without encryption headers.

<details>
<summary>Answer</summary>

**B.** An SCP (Service Control Policy) is the only mechanism that can PREVENT bucket creation without the specified encryption. SCPs apply to all users and roles in the account (or organizational unit), including administrators. The deny condition ensures that any `CreateBucket` call without the correct KMS key specification is rejected before the bucket exists.

**A is wrong**: S3 default encryption applies encryption to objects uploaded without specifying encryption. But it does not prevent creating buckets with different encryption settings. Someone could create a bucket with SSE-S3 or no default encryption and upload unencrypted objects.

**C is wrong**: AWS Config detects non-compliance after the fact. The bucket is created unencrypted first, then Config flags it, then auto-remediation applies encryption. There is a window where the bucket exists without the correct encryption. The question says "prevent," not "detect and fix."

**D is wrong**: This protects objects (`PutObject`) but not bucket creation. A user could create an unencrypted bucket and it would exist until someone tries to upload to it. Also, IAM policies can be overridden by IAM administrators. SCPs cannot be overridden except by the organization management account.
</details>

---

## Part 4: Exam Day Tips

### Time management

You have 130 minutes for 65 questions. That is exactly 2 minutes per question.

- **First pass (80 minutes)**: Answer every question you are confident about. Flag questions you are unsure about. Do not spend more than 2 minutes on any single question. If you are stuck, flag it and move on.
- **Second pass (40 minutes)**: Return to flagged questions. You now have context from the entire exam, which sometimes helps with earlier questions.
- **Buffer (10 minutes)**: Review flagged questions one final time. Change answers only if you have a specific reason.

Most people finish with 15-20 minutes to spare. If you are running out of time, answer every remaining question -- there is no penalty for wrong answers.

### Elimination strategy

Every question has 4 answers. If you can eliminate 2, your odds go from 25% to 50%. Look for these immediate disqualifiers:

1. **Service does not do that**: "Use CloudFront to block SQL injection" -- CloudFront is a CDN, not a WAF. Eliminated.
2. **Service limit violation**: "Use Lambda for a 2-hour processing job" -- Lambda max is 15 minutes. Eliminated.
3. **Wrong layer**: "Use NACLs for application-level filtering" -- NACLs operate at Layer 3/4, not Layer 7. Eliminated.
4. **Cost mismatch**: "Use Shield Advanced for a startup" -- $3,000/month is not "cost-effective" for a small company. Eliminated.

### Key words that signal the answer

The exam uses specific phrases that point toward specific answers. Learn to recognize them:

| Phrase | Likely Answer |
|--------|--------------|
| **"Most cost-effective"** | Spot Instances, S3 lifecycle policies, right-sizing, Reserved Instances |
| **"Least operational overhead"** | Managed services (Lambda, Fargate, Aurora Serverless, managed rules) |
| **"Highly available"** | Multi-AZ deployment, ALB + ASG, RDS Multi-AZ, Aurora |
| **"Disaster recovery"** | Multi-region, Cross-Region Replication, Route 53 failover, Aurora Global Database |
| **"Decouple"** | SQS between producer and consumer |
| **"Fan-out"** | SNS with multiple SQS subscribers |
| **"Millisecond latency"** | DynamoDB (single-digit) or ElastiCache (sub-millisecond) |
| **"Temporary credentials"** | STS AssumeRole, not long-lived access keys |
| **"Automatic rotation"** | Secrets Manager, not SSM Parameter Store |
| **"Block specific IP"** | NACL deny rule (security groups cannot deny) |
| **"Encrypt at rest"** | KMS (CMK if cross-account, AWS managed if not) |
| **"Without traversing the internet"** | VPC endpoint (Gateway for S3/DynamoDB, Interface for others) |
| **"Stateless application"** | Store session state in ElastiCache or DynamoDB, not local disk |
| **"Compliance / audit"** | CloudTrail, AWS Config, KMS CMK audit |
| **"Burst traffic"** | Auto Scaling group, DynamoDB on-demand, Lambda |
| **"Regulatory requirement for data residency"** | Route 53 geolocation routing, specific region deployment |
| **"Prevent"** | SCP (preventive) vs Config (detective) |
| **"Detect"** | GuardDuty (threats), Config (compliance), Inspector (vulnerabilities) |

### Common distractors

The exam reuses certain wrong-answer patterns. Recognizing them saves time:

1. **The "technically works but overly complex" answer**: Custom Lambda + CloudWatch Events + SNS when a managed service does the same thing in one step. Always pick the simpler managed solution.

2. **The "right service, wrong feature" answer**: "Use RDS read replicas for high availability." Read replicas are for read scaling, not HA. Multi-AZ is for HA. Same service, different feature.

3. **The "expensive but correct" answer**: Shield Advanced when Shield Standard suffices. Aurora Global Database when a single-region RDS Multi-AZ meets the requirements. The exam qualifies "most cost-effective" -- if it does not, any correct solution works, but prefer the simpler one.

4. **The "deprecated or obscure" answer**: Launch Configurations (replaced by Launch Templates). Classic Load Balancer (replaced by ALB/NLB). If an answer uses an older service and a newer equivalent is available, the newer one is almost always correct.

5. **The "sounds secure but does not solve the problem" answer**: "Enable MFA" when the question is about encrypting data at rest. MFA is always good, but it does not encrypt anything. The exam tests whether you can match the security control to the specific threat.

### The "FIRST" and "MOST" qualifiers

When a question says "What should the architect do FIRST?":
- Prioritize containment over investigation (deactivate compromised keys before analyzing CloudTrail)
- Prioritize prevention over remediation (block the attack before cleaning up)
- Prioritize the simplest effective action (do not redesign the architecture when changing a security group fixes the immediate issue)

When a question says "MOST cost-effective" or "LEAST operational overhead":
- There may be multiple technically correct answers. The qualifier tells you which dimension to optimize for.
- "Most cost-effective" = cheapest solution that fully meets requirements.
- "Least operational overhead" = most managed, least custom code, fewest moving parts.

### Final checklist before exam day

- [ ] Know all 5 Well-Architected pillars and their design principles
- [ ] Know every service comparison in the Decision Matrix (Part 2)
- [ ] Know S3 storage classes and when to use each
- [ ] Know EC2 pricing models (On-Demand, Reserved, Savings Plans, Spot, Dedicated)
- [ ] Know Security Group vs NACL (stateful vs stateless)
- [ ] Know RDS Multi-AZ vs Read Replicas vs Aurora Global Database
- [ ] Know DR strategies and their RTO/RPO/cost tradeoffs
- [ ] Know when to use Secrets Manager vs SSM Parameter Store
- [ ] Know when to use SQS vs SNS vs EventBridge
- [ ] Know VPC networking: public/private subnets, NAT Gateway, VPC endpoints
- [ ] Know ALB vs NLB (Layer 7 vs Layer 4, WAF compatibility)
- [ ] Know Route 53 routing policies and when to use each
- [ ] Know CloudFront vs Global Accelerator
- [ ] Know KMS key types and when to use each
- [ ] Know the difference between preventive (SCP, IAM) and detective (Config, GuardDuty) controls

You have built real infrastructure. You understand why these services exist because you have used them. That is an advantage most exam-takers do not have. Trust what you built. Apply that understanding to scenarios you have not seen. That is what the exam tests.
