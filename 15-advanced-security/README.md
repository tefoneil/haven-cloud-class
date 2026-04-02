# Module 15: Advanced Security

> **Maps to:** SAA-C03 Domain 1 — Design Secure Architectures (30% of exam) | **Services:** KMS, WAF, Shield, GuardDuty, Secrets Manager, AWS Config, CloudTrail
>
> **Type:** Conceptual (no build/teardown) | **Prerequisites:** Module 07 (Security Hardening)

---

## The Problem

Haven handles 30 API keys. Helius, Telegram Bot Token, CoinGecko, Alpaca, CryptoPanic, LunarCrush, Chainstack RPC, Finnhub, and more. Every one of those keys, if compromised, gives an attacker the ability to act as Haven -- read market data, send Telegram messages, or in the case of Alpaca, execute real trades on a brokerage account.

Module 07 covered the operational layer: IAM least-privilege, fail2ban, key-only SSH, security groups. That is the "keep people out of the server" layer. It is real, it is deployed, and it is working.

But the SAA-C03 does not stop at IAM and security groups. Domain 1 is 30% of the exam -- the single largest domain -- and it tests services that Haven has not deployed because they are either too expensive for a single-instance architecture (WAF, Shield Advanced), too complex to justify at this scale (KMS custom key policies), or solve problems Haven does not have yet (GuardDuty threat detection on a VPC with one instance).

This module bridges that gap. For each service, we cover three things:

1. **What it does** -- the core concept
2. **How Haven would use it** -- concrete scenario, not abstract theory
3. **What the exam asks** -- the specific patterns SAA-C03 tests

You do not need to deploy any of these services. You need to understand when to choose each one and why.

---

## Encryption: The Foundation

Every security question on the SAA-C03 eventually comes back to encryption. There are two states data can be in, and each has different protection mechanisms.

### Encryption in transit

Data moving between two points. Haven's daemon makes HTTPS calls to CoinGecko, sends messages via the Telegram Bot API, writes heartbeat metrics to CloudWatch. All of these use TLS (Transport Layer Security) -- the data is encrypted while it travels over the network.

AWS enforces TLS on its own APIs. You do not configure this. When Haven calls `aws cloudwatch put-metric-data`, the AWS SDK uses HTTPS automatically. The exam will not ask you to configure TLS for AWS API calls. It will ask about TLS in the context of:

- **S3 bucket policies** that enforce `aws:SecureTransport` (deny HTTP, require HTTPS)
- **Load balancer listeners** (HTTPS termination at ALB, TLS passthrough at NLB)
- **Database connections** (RDS `require_ssl` parameter, Aurora TLS enforcement)

### Encryption at rest

Data sitting on a disk, in a database, or in an S3 bucket. Haven's SQLite database at `data/haven.db` contains 233K messages, 31K signals, and 24K wallet records. The EBS volume it sits on can be encrypted. The S3 backup bucket can be encrypted. The SSM parameters holding API keys are already encrypted (SecureString uses KMS under the hood).

This is where KMS enters the picture.

---

## KMS (Key Management Service)

KMS is the encryption key management service. It does not encrypt your data directly -- it manages the keys that other services use to encrypt your data.

### Key types

| Key Type | Who Manages It | Cost | Use Case |
|----------|---------------|------|----------|
| **AWS owned keys** | AWS entirely | Free | Default S3 encryption (SSE-S3) |
| **AWS managed keys** | AWS creates, you use | Free (per-use charges) | SSM SecureString default, EBS default encryption |
| **Customer managed keys (CMK)** | You create and control | $1/month + per-use | Custom key policies, automatic rotation, cross-account access |

Haven's SSM SecureStrings use an AWS managed key. When you run `aws ssm put-parameter --type SecureString`, AWS encrypts the value using the `aws/ssm` KMS key. You never created this key -- AWS did. You cannot delete it, rotate it, or change its policy.

**When would Haven use a CMK?** If Haven needed to share encrypted data with another AWS account (say, a separate production account), you would create a CMK with a key policy granting both accounts access. AWS managed keys cannot do cross-account sharing.

### Key policies vs IAM policies

This is an exam favorite. KMS keys have their own resource-based policies (key policies), and access requires BOTH the key policy AND IAM to allow the action. This is different from S3 or SQS, where either a resource policy or IAM policy can grant access independently.

```
Can the user use the KMS key?
  --> Does the KEY POLICY allow it?  (must be yes)
  --> Does the IAM POLICY allow it?  (must also be yes)
  --> Access granted only if BOTH say yes
```

### Automatic key rotation

- **AWS managed keys**: Automatically rotated every year. You cannot change this.
- **Customer managed keys**: You can enable automatic rotation (every year). The old key material is preserved for decryption -- only new encryptions use the new key.
- **Customer managed keys with imported key material**: No automatic rotation. You must rotate manually.

### Exam pattern

> "A company needs to encrypt data at rest and must be able to audit key usage. They also need to rotate keys annually and share encrypted data with a partner account."

Answer: Customer managed KMS key. AWS managed keys cannot do cross-account. AWS owned keys have no audit trail. The "audit key usage" requirement points to CMK (CloudTrail logs every KMS API call for CMKs).

---

## S3 Encryption Options

The exam loves S3 encryption. There are four options, and you need to know when to use each.

| Option | Key Management | HTTPS Required? | Use Case |
|--------|---------------|-----------------|----------|
| **SSE-S3** | AWS owns and manages everything | No | Default. "Just encrypt it." |
| **SSE-KMS** | You choose a KMS key (AWS managed or CMK) | No | Audit trail, key rotation control, cross-account |
| **SSE-C** | You provide the key with every request | **Yes** (must use HTTPS) | Regulatory requirement to manage your own keys |
| **Client-side** | You encrypt before uploading | Depends | Data must be encrypted before it leaves the application |

Haven's S3 backup bucket should use **SSE-S3** or **SSE-KMS with the AWS managed key**. There is no cross-account requirement, no regulatory mandate to manage keys, and no reason to add complexity. The exam tests whether you can identify these scenarios.

### The S3 bucket key optimization

When using SSE-KMS, every S3 PUT and GET generates a KMS API call. At scale, this adds cost and can hit KMS request rate limits (5,500-30,000 requests/second depending on region). S3 Bucket Keys solve this by caching a short-lived data key at the bucket level, reducing KMS calls by up to 99%.

**Exam trigger**: "reduce cost of SSE-KMS encryption" or "KMS request throttling on S3."

---

## Secrets Manager vs SSM Parameter Store

Haven uses SSM Parameter Store (Module 06). Every API key is stored as a SecureString under `/haven/`. This works. But the exam will present scenarios where Secrets Manager is the right answer instead.

| Feature | SSM Parameter Store | Secrets Manager |
|---------|-------------------|-----------------|
| **Cost** | Free (Standard), $0.05/10K calls (Advanced) | $0.40/secret/month + $0.05/10K calls |
| **Automatic rotation** | No | **Yes** (Lambda-based) |
| **Cross-account sharing** | No | **Yes** (resource policies) |
| **Max size** | 8 KB (Advanced) | 64 KB |
| **RDS integration** | Manual | **Native** (auto-rotates DB passwords) |
| **Versioning** | Limited | Full version history |

### When to choose Secrets Manager

The exam answer is Secrets Manager when the question mentions any of these:

- **Automatic rotation** of credentials
- **RDS database passwords** that need to rotate without application downtime
- **Cross-account secret sharing**
- **Compliance requirement** for credential rotation

### When to choose SSM Parameter Store

- **Configuration values** (not secrets) like feature flags, endpoint URLs
- **Cost sensitivity** -- SSM is free for standard parameters
- **Simple secret storage** without rotation needs (Haven's use case)

**Haven scenario**: If Haven moved from SQLite to RDS, the database password should go in Secrets Manager with automatic rotation enabled. The Lambda rotation function would update the password in RDS and in Secrets Manager simultaneously, ensuring Haven always reads the current password. With SSM, you would have to build this rotation logic yourself.

---

## WAF (Web Application Firewall)

WAF protects HTTP/HTTPS endpoints from common web attacks. It sits in front of:

- **CloudFront distributions**
- **Application Load Balancers**
- **API Gateway REST APIs**
- **AppSync GraphQL APIs**

WAF does NOT sit in front of EC2 instances directly, NLBs, or Route 53.

### How Haven would use WAF

Haven does not have a web endpoint today. But the architecture roadmap includes TradingView webhook integration -- TradingView sends HTTP POST requests to Haven when chart conditions trigger. That webhook endpoint would be exposed via API Gateway or ALB. WAF would protect it from:

- **SQL injection** in POST body parameters
- **Rate limiting** -- block IPs sending more than 100 requests per minute
- **Geo-blocking** -- TradingView sends from known IP ranges; block everything else
- **Bot protection** -- prevent automated scanners from probing the endpoint

### WAF rules and Web ACLs

A Web ACL (Access Control List) contains rules. Rules are evaluated in priority order (lowest number first). Each rule either ALLOWS, BLOCKS, or COUNTS matching requests.

**Managed rule groups** are pre-built by AWS or AWS Marketplace sellers:

- `AWSManagedRulesCommonRuleSet` -- SQLi, XSS, bad bots
- `AWSManagedRulesSQLiRuleSet` -- SQL injection specifically
- `AWSManagedRulesAmazonIpReputationList` -- known bad IPs
- `AWSManagedRulesBotControlRuleSet` -- bot detection (additional cost)

**Custom rules** let you write your own conditions:

```
IF request rate > 100/5min from same IP
  THEN BLOCK
```

### Exam pattern

> "A company needs to protect its ALB-hosted application from SQL injection attacks with minimal operational overhead."

Answer: AWS WAF with `AWSManagedRulesCommonRuleSet`. "Minimal operational overhead" means use managed rules, not custom rules. WAF + ALB is a valid pairing.

---

## Shield

Shield protects against DDoS (Distributed Denial of Service) attacks.

### Shield Standard

- **Free.** Automatically enabled on every AWS account.
- Protects against the most common Layer 3/4 (network/transport) DDoS attacks
- Works with CloudFront, Route 53, ALB, NLB, Elastic IP
- No configuration needed. You already have it.

Haven has Shield Standard right now. Every AWS customer does.

### Shield Advanced

- **$3,000/month** (1-year commitment). Plus data transfer fees.
- 24/7 access to the DDoS Response Team (DRT) -- AWS engineers who actively mitigate attacks
- **Cost protection** -- AWS credits your account for scaling charges caused by DDoS attacks (the "you got attacked and your ALB auto-scaled to 500 instances" scenario)
- Advanced attack visibility and metrics
- WAF is included at no additional charge when combined with Shield Advanced
- Health-based detection using Route 53 health checks

**When does the exam pick Shield Advanced?** When the scenario mentions:

- **Financial services** or **mission-critical** applications
- **DDoS cost protection** needed
- **24/7 expert response team** required
- The $3,000/month cost is justified by the business impact of downtime

Haven would not use Shield Advanced. The cost is 150x Haven's entire monthly AWS bill. But if Haven were processing real financial transactions at scale, the cost protection alone could justify it -- one DDoS-triggered auto-scaling event could cost more than $3,000.

---

## GuardDuty

GuardDuty is an intelligent threat detection service. It continuously analyzes:

- **VPC Flow Logs** -- unusual network traffic patterns
- **CloudTrail management events** -- suspicious API calls
- **CloudTrail S3 data events** -- unusual S3 access patterns
- **DNS query logs** -- communication with known malicious domains
- **EKS audit logs** -- Kubernetes-specific threats
- **Lambda network activity** -- unusual function behavior

GuardDuty uses machine learning to establish a baseline of "normal" activity and then flags deviations.

### How Haven would trigger GuardDuty findings

- **Unusual API calls**: If someone used Haven's IAM credentials from a new IP address or geographic location, GuardDuty would flag it as `UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B` (or similar)
- **Bitcoin mining detection**: GuardDuty specifically detects cryptocurrency mining behavior (DNS queries to mining pools, connections to mining-related IPs). If the EC2 instance were compromised and used for mining, GuardDuty would catch it immediately.
- **Port scanning**: If Haven's instance started scanning other IPs (sign of a compromised instance), GuardDuty flags `Recon:EC2/PortProbeUnprotectedPort`
- **S3 bucket exfiltration**: If someone dumped the entire backup bucket to an external account, GuardDuty flags `Exfiltration:S3/AnomalousBehavior`

### GuardDuty findings and remediation

GuardDuty generates findings with severity levels (Low, Medium, High). It does not automatically remediate -- it tells you something is wrong. For automated remediation, you connect GuardDuty to EventBridge, which triggers a Lambda function to take action (isolate the instance, revoke credentials, etc.).

```
GuardDuty Finding --> EventBridge Rule --> Lambda Function --> Remediate
                                                          --> SNS --> Alert team
```

### Pricing

GuardDuty charges per volume of data analyzed:

- CloudTrail management events: Free for 30 days, then per million events
- VPC Flow Logs: Per GB analyzed
- DNS logs: Per million queries

For Haven's single-instance architecture, GuardDuty would cost roughly $2-5/month. Cheap insurance for threat detection.

### Exam pattern

> "A company needs to detect if any of their EC2 instances have been compromised and are communicating with known command-and-control servers."

Answer: GuardDuty. It specifically monitors for C2 communication patterns. Security Hub aggregates findings but does not detect threats itself.

---

## AWS Config

AWS Config continuously monitors and records your AWS resource configurations. It answers the question: "Is my infrastructure configured the way it should be?"

### Config Rules

Config rules evaluate whether resources comply with your desired configuration. Examples:

| Rule | What It Checks | Haven Relevance |
|------|---------------|-----------------|
| `s3-bucket-public-read-prohibited` | No public S3 buckets | Backup bucket must stay private |
| `encrypted-volumes` | All EBS volumes encrypted | Haven's 20GB gp3 volume |
| `restricted-ssh` | SSH not open to 0.0.0.0/0 | Security group must be IP-scoped |
| `iam-user-mfa-enabled` | MFA on all IAM users | HavenDev should have MFA |
| `ec2-instance-no-public-ip` | Instances in private subnets | Not applicable (Haven needs public IP) |

Config rules can be **AWS managed** (pre-built, like the list above) or **custom** (Lambda-backed).

### Compliance timeline

Config keeps a history of all resource changes. You can answer: "Who changed the security group at 3 AM? What was the previous configuration?" This is the forensic investigation tool.

### Exam pattern

> "A company needs to ensure all S3 buckets are encrypted and receive automatic notifications when a bucket is created without encryption."

Answer: AWS Config rule (`s3-bucket-server-side-encryption-enabled`) with auto-remediation via Systems Manager Automation. Config detects non-compliance, SSM Automation enables encryption.

---

## CloudTrail

CloudTrail logs every API call made in your AWS account. Every `RunInstances`, every `PutObject`, every `CreateUser`. It is the audit trail.

### Management events vs data events

| Event Type | What It Logs | Default | Cost |
|-----------|-------------|---------|------|
| **Management events** | Control plane operations (create, delete, modify resources) | **Enabled by default** (90 days) | Free (1 trail) |
| **Data events** | Data plane operations (S3 GetObject/PutObject, Lambda invocations) | **Disabled by default** | Per 100K events |

Haven's CloudTrail is already logging management events -- every `put-parameter`, `put-metric-data`, `run-instances` call is recorded. Data events (like individual S3 object reads during backup verification) are not logged by default.

### CloudTrail Lake vs S3 delivery

- **S3 delivery** (default): CloudTrail writes JSON log files to an S3 bucket. You query them with Athena.
- **CloudTrail Lake**: Managed event data store with SQL query support. More expensive but easier to search.

### Multi-region and organization trails

- A **multi-region trail** captures events from all regions (essential -- an attacker will use a region you are not watching)
- An **organization trail** captures events from all accounts in an AWS Organization

### Exam pattern

> "A company needs to investigate who deleted an S3 bucket and when."

Answer: CloudTrail management events. Bucket deletion is a control plane operation, logged by default. Check the `DeleteBucket` event for the IAM principal and timestamp.

> "A company needs to log all read access to sensitive files in S3."

Answer: Enable CloudTrail S3 data events for the specific bucket. Data events are not enabled by default.

---

## VPC Flow Logs

VPC Flow Logs capture network traffic metadata (not content) for network interfaces in your VPC. They record:

- Source and destination IP addresses
- Source and destination ports
- Protocol (TCP, UDP, ICMP)
- Packet and byte counts
- **Accept or reject** action

Flow logs can be attached at three levels:

| Level | Captures |
|-------|----------|
| **VPC** | All ENIs in the VPC |
| **Subnet** | All ENIs in the subnet |
| **ENI (interface)** | Single network interface |

### Haven use case

If Haven's daemon suddenly starts making connections to unknown IP addresses, VPC Flow Logs would show the destination IPs, ports, and volume of traffic. Combined with GuardDuty (which analyzes flow logs automatically), this provides network-level forensics.

Flow logs are sent to CloudWatch Logs, S3, or Kinesis Data Firehose. For Haven, CloudWatch Logs is the simplest destination -- you can set a retention period and search them with CloudWatch Logs Insights.

### What flow logs do NOT capture

- DNS queries (use Route 53 Resolver query logs)
- Traffic to/from 169.254.169.254 (instance metadata service)
- DHCP traffic
- Traffic to the VPC DNS server (the .2 address)
- Actual packet content (flow logs are metadata only)

---

## Security Group vs NACL

This comparison appears on every SAA-C03 exam. Module 01 introduced security groups. Here is the full comparison.

| Feature | Security Group | Network ACL (NACL) |
|---------|---------------|-------------------|
| **Scope** | ENI (instance) level | Subnet level |
| **State** | **Stateful** -- return traffic automatically allowed | **Stateless** -- must explicitly allow return traffic |
| **Rules** | Allow only (no deny rules) | Allow AND deny rules |
| **Evaluation** | All rules evaluated together | Rules evaluated in number order, first match wins |
| **Default** | Deny all inbound, allow all outbound | Allow all inbound and outbound |
| **Association** | One instance can have multiple SGs | One subnet has exactly one NACL |

### The stateful vs stateless distinction

This is the single most important networking concept on the exam.

**Security group (stateful)**: Haven's security group allows inbound SSH on port 22. When you SSH in and get a response, the return traffic (from Haven back to your laptop) is automatically allowed. You do not need an outbound rule for SSH responses. The security group "remembers" the connection.

**NACL (stateless)**: If you add a NACL rule allowing inbound port 22, you ALSO need an outbound rule allowing ephemeral ports (1024-65535) for the response. The NACL does not track connections. It evaluates every packet independently.

### Exam pattern

> "A solutions architect needs to block a specific IP address from accessing resources in a subnet."

Answer: NACL. Security groups cannot deny -- they can only allow. To block a specific IP, you need a NACL deny rule with a lower rule number than the allow-all rule.

> "Traffic is being allowed inbound but responses are being dropped."

Answer: NACL missing outbound ephemeral port rule. This is the classic stateless gotcha.

---

## Exam Scenarios: Practice Questions

These cover the most common security patterns on the SAA-C03.

### Scenario 1: Encryption key management

> A crypto trading platform stores API keys for 12 exchange integrations in AWS. The keys must be rotated every 90 days, and auditors need a log of every time a key is accessed. Which combination of services meets these requirements?

**A.** SSM Parameter Store SecureString with a CloudWatch Events rule triggering Lambda for rotation

**B.** Secrets Manager with automatic rotation and CloudTrail logging

**C.** KMS CMK with key rotation enabled and AWS Config rules

**D.** S3 encrypted with SSE-KMS and S3 Object Lock

**Answer: B.** Secrets Manager provides native automatic rotation (Lambda-based) on custom schedules including 90 days. CloudTrail automatically logs all Secrets Manager API calls. SSM Parameter Store (A) does not have automatic rotation -- you would have to build it yourself. KMS (C) rotates encryption keys, not application secrets. S3 Object Lock (D) prevents deletion, not rotation.

### Scenario 2: DDoS protection with cost protection

> A financial services company runs a customer-facing API on ALB. During a recent DDoS attack, the ALB auto-scaled to absorb traffic, generating a $47,000 AWS bill. How should the architect prevent this cost impact in future attacks?

**A.** AWS WAF with rate-limiting rules on the ALB

**B.** AWS Shield Advanced with DDoS cost protection

**C.** CloudFront distribution with geographic restrictions

**D.** NLB with fixed IP addresses and security group rules

**Answer: B.** Shield Advanced includes DDoS cost protection -- AWS credits scaling charges caused by DDoS attacks. WAF (A) helps block attack traffic but does not provide cost protection for traffic that gets through. CloudFront (C) absorbs some attack traffic but does not credit costs. NLB (D) does not help with application-layer DDoS.

### Scenario 3: Threat detection

> An operations team discovers that an EC2 instance is making DNS queries to a known cryptocurrency mining pool. They need a service that would have detected this automatically. Which service should they enable?

**A.** AWS Config with custom rules

**B.** Amazon Inspector

**C.** Amazon GuardDuty

**D.** VPC Flow Logs with CloudWatch Logs Insights queries

**Answer: C.** GuardDuty specifically detects cryptocurrency mining behavior by analyzing DNS query patterns, VPC Flow Logs, and CloudTrail events. It uses threat intelligence feeds to identify known mining pool domains. Inspector (B) assesses vulnerabilities in software, not runtime behavior. AWS Config (A) checks configuration compliance, not active threats. VPC Flow Logs (D) would show the traffic but require manual analysis to identify mining.

### Scenario 4: S3 encryption in transit

> A compliance requirement mandates that all data uploaded to an S3 bucket must use HTTPS. How should the architect enforce this?

**A.** Enable SSE-S3 default encryption on the bucket

**B.** Create a bucket policy with a condition denying requests where `aws:SecureTransport` is `false`

**C.** Enable S3 Transfer Acceleration

**D.** Configure the bucket to use SSE-KMS with a CMK

**Answer: B.** The `aws:SecureTransport` condition key in a bucket policy enforces HTTPS. Requests using HTTP are denied. SSE-S3 (A) and SSE-KMS (D) are encryption at rest, not in transit. Transfer Acceleration (C) speeds up uploads but does not enforce HTTPS.

### Scenario 5: Cross-account secret sharing

> Two AWS accounts need to share a database password. The password must be rotated automatically and both accounts must always have the current version. Which service should be used?

**A.** SSM Parameter Store with cross-account IAM roles

**B.** Secrets Manager with a resource-based policy granting the second account access

**C.** KMS CMK with a cross-account key policy

**D.** S3 bucket with cross-account bucket policy containing the encrypted password

**Answer: B.** Secrets Manager supports resource-based policies for cross-account access and automatic rotation. SSM Parameter Store (A) does not support resource-based policies for cross-account sharing. KMS (C) shares encryption keys, not secrets. S3 (D) would work mechanically but is not designed for secret management and lacks rotation.

### Scenario 6: Blocking a malicious IP

> An application in a public subnet is receiving malicious requests from a specific IP address. The security group currently allows HTTP from 0.0.0.0/0. What is the fastest way to block this IP?

**A.** Remove the allow-all inbound HTTP rule from the security group

**B.** Add a deny rule to the security group for the malicious IP

**C.** Add a deny rule to the subnet's NACL for the malicious IP with a low rule number

**D.** Enable GuardDuty to automatically block the IP

**Answer: C.** NACLs support deny rules. Security groups (B) cannot deny -- they only allow. Removing the allow-all rule (A) would block all HTTP traffic, not just the malicious IP. GuardDuty (D) detects threats but does not automatically block IPs.

### Scenario 7: Auditing S3 object access

> A company needs to determine which IAM user downloaded a specific file from S3 last Tuesday. CloudTrail management events are enabled but show no relevant entries. What is missing?

**A.** CloudTrail is not configured for multi-region logging

**B.** CloudTrail S3 data events are not enabled for the bucket

**C.** VPC Flow Logs are not capturing S3 traffic

**D.** S3 server access logging is not enabled

**Answer: B.** S3 GetObject is a data event, not a management event. Data events must be explicitly enabled in CloudTrail. Multi-region (A) would not help because data events are disabled regardless of region. VPC Flow Logs (C) show network-level traffic but not which IAM user made the request. S3 access logging (D) records requests but does not include IAM principal information in the same detail as CloudTrail.

---

## Quick Reference: Security Service Decision Tree

```
Need to encrypt data at rest?
  --> S3: SSE-S3 (default) or SSE-KMS (audit/cross-account)
  --> EBS: Enable volume encryption (AES-256, KMS-backed)
  --> RDS: Enable encryption at creation (cannot add later!)

Need to manage secrets?
  --> Automatic rotation needed? --> Secrets Manager
  --> Just storage, no rotation? --> SSM Parameter Store
  --> Database password rotation? --> Secrets Manager (native RDS integration)

Need to protect a web endpoint?
  --> HTTP attacks (SQLi, XSS)? --> WAF
  --> DDoS with cost protection? --> Shield Advanced
  --> DDoS basic protection? --> Shield Standard (already enabled)

Need to detect threats?
  --> Runtime threat detection? --> GuardDuty
  --> Vulnerability scanning? --> Inspector
  --> Configuration compliance? --> AWS Config

Need to investigate an incident?
  --> Who made an API call? --> CloudTrail
  --> What network traffic occurred? --> VPC Flow Logs
  --> What was the resource config at the time? --> AWS Config timeline

Need to block traffic?
  --> Block a specific IP at subnet level? --> NACL deny rule
  --> Restrict instance access to known IPs? --> Security Group allow rules
  --> Block HTTP attack patterns? --> WAF rules
```

---

## Key Takeaways for the Exam

1. **KMS key types**: AWS owned (free, invisible) < AWS managed (free, visible, no control) < Customer managed (paid, full control). Cross-account requires CMK.

2. **Secrets Manager vs SSM**: Automatic rotation = Secrets Manager. Always. The exam will try to trick you with "least cost" but if rotation is mentioned, cost is irrelevant.

3. **WAF attaches to ALB, CloudFront, API Gateway, AppSync.** Never directly to EC2 or NLB.

4. **Shield Standard is free and always on.** Shield Advanced is $3,000/month and includes DDoS cost protection.

5. **GuardDuty detects. It does not remediate.** For automated remediation: GuardDuty -> EventBridge -> Lambda.

6. **Security groups are stateful (no return traffic rules needed). NACLs are stateless (return traffic rules required).** This single fact answers 5-10% of all SAA-C03 questions.

7. **CloudTrail management events are free and on by default. Data events cost money and are off by default.** "Who accessed this S3 object?" = data events.

8. **NACLs can deny. Security groups cannot.** If the question says "block," think NACL.

---

## Haven's Security Stack: What We Built vs What the Exam Tests

| Layer | Haven (Deployed) | Exam (Know This) |
|-------|-----------------|-------------------|
| **Identity** | IAM least-privilege policy (Module 07) | IAM policies, roles, federation, STS |
| **Secrets** | SSM Parameter Store SecureString (Module 06) | Secrets Manager rotation, cross-account |
| **Network** | Security group, key-only SSH (Module 07) | NACL vs SG, VPC Flow Logs, VPC endpoints |
| **Host** | fail2ban (Module 07) | Inspector, Systems Manager Patch Manager |
| **Encryption** | SSM KMS (automatic), S3 SSE (Module 04) | KMS CMK policies, S3 encryption options |
| **Monitoring** | CloudWatch alarms (Module 05) | GuardDuty, Config, CloudTrail data events |
| **DDoS** | Shield Standard (automatic) | Shield Advanced, WAF rules |
| **Web** | None (no HTTP endpoints yet) | WAF + ALB, WAF + CloudFront |

You built the foundation. The exam tests the full stack. This module fills the gap.
