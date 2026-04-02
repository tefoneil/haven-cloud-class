# Module 09: Databases — "Haven Outgrows SQLite"

> **Maps to:** SAA-C03 Domains 2, 3 | **Services:** RDS, Aurora, DynamoDB
>
> **Time to complete:** ~60 minutes | **Prerequisites:** Module 01 (VPC basics), Module 06 (SSM for credentials)

---

## The Problem

Haven's database is a single SQLite file: `data/haven.db`, 574MB, sitting on an EBS volume attached to one EC2 instance.

It has corrupted twice.

The first corruption was an orphan index left behind after a migration dropped a table but not its auto-generated `sqlite_autoindex`. Every query in the daemon started failing with `malformed database schema`. The fix was PRAGMA surgery on the live database — deleting the orphan row from `sqlite_master` with `writable_schema=ON`. That fixed the orphan but exposed a deeper corruption: `signal_outcomes` had an invalid rootpage. We restored from a backup and re-applied migrations.

The second corruption came from the same family. A rename-copy-drop migration pattern caused SQLite to silently update foreign key references in five other tables to point at the old (now-deleted) table name. Inserts into those tables failed silently. The daemon logged "Created 51 new tracking rows" every 60 seconds, but zero rows actually persisted. An open trade was up +63% with no exit monitoring because the tracking table was broken.

Both corruptions share a root cause: SQLite is an embedded database designed for single-writer workloads. Haven is a 34-loop async daemon where multiple coroutines read and write the same tables concurrently. SQLite handles this through WAL mode and file-level locking, but it was never designed for this access pattern. It works until it doesn't, and when it doesn't, the failure mode is silent data loss.

Beyond corruption, there are operational problems:

- **No automatic failover.** If the EBS volume fails or the instance terminates, the database is gone until you restore from an S3 backup (Module 04). Downtime is measured in minutes to hours depending on how quickly you notice.
- **No read scaling.** Every query hits the same file. The daemon's 34 loops, the Streamlit dashboard, and ad-hoc analysis queries all compete for the same SQLite lock.
- **Backups are manual.** The cron job from Module 04 dumps the database to S3 every 6 hours. If the instance dies between backups, you lose up to 6 hours of signal data, paper trades, and outcome tracking.
- **No point-in-time recovery.** You can restore to the last backup, but not to "3:47 PM yesterday, right before that bad migration ran."

What if Haven used a managed database?

---

## The Concept

AWS offers three database services that could replace Haven's SQLite. Each solves different problems.

### RDS (Relational Database Service)

RDS is a managed relational database. You pick an engine (PostgreSQL, MySQL, MariaDB, Oracle, SQL Server), an instance size, and a storage amount. AWS handles provisioning, patching, backups, and failover. You get a hostname and port. Your application connects to it like any other database.

For Haven, RDS PostgreSQL is the natural fit. Haven's schema is relational — 70 tables with foreign keys, complex JOIN queries for the dashboard, and aggregate queries for outcome analysis. The migration from SQLite to PostgreSQL is straightforward because SQLite's SQL dialect is close to PostgreSQL's (with some differences around auto-increment and datetime handling).

**Key RDS features:**

| Feature | What It Does | Haven Benefit |
|---------|-------------|---------------|
| **Multi-AZ** | Synchronous standby in another AZ | Automatic failover if primary dies |
| **Read Replicas** | Async copies for read traffic | Dashboard queries don't compete with daemon writes |
| **Automated Backups** | Daily snapshots + transaction logs | Point-in-time recovery to any second in the retention window |
| **Encryption** | AES-256 at rest, SSL in transit | Wallet addresses and API data encrypted |
| **Monitoring** | CloudWatch metrics built in | Connections, IOPS, replication lag on the dashboard |

### Aurora

Aurora is AWS's custom-built relational database engine. It is compatible with MySQL and PostgreSQL (you can use the same drivers, same SQL, same tools) but the storage layer is completely different. Instead of writing to a local EBS volume, Aurora writes to a distributed storage system that automatically replicates data across three Availability Zones.

The headline number is "5x throughput of standard MySQL, 3x of standard PostgreSQL." The practical benefit for Haven is not raw throughput — Haven's write volume is modest — but the storage architecture. Aurora's storage is self-healing: if a disk segment fails, it repairs itself from the other copies without any downtime or operator intervention. The corruption scenarios that hit Haven's SQLite cannot happen with Aurora's storage layer.

Aurora costs more than RDS. The minimum instance is `db.t3.medium` (~$50/month), compared to RDS `db.t3.micro` (~$13/month). For Haven's current scale, RDS is sufficient. Aurora becomes the right choice when you need the storage resilience or when read replica count exceeds what RDS handles efficiently (Aurora supports up to 15 read replicas vs RDS's 5).

### DynamoDB

DynamoDB is a different animal entirely. It is not relational. There is no SQL (well, there is PartiQL, but the mental model is different). There are no JOINs. There are no foreign keys. You define a table with a partition key and an optional sort key, and you access data by those keys.

DynamoDB is serverless — there are no instances to manage, no storage to provision, no patches to apply. You create a table and start writing to it. It scales automatically from zero to millions of requests per second. You pay per read and write operation (on-demand mode) or provision a fixed capacity (provisioned mode).

For Haven, DynamoDB is wrong for the core schema. Haven's 70 relational tables with foreign keys and complex queries are a poor fit for key-value access. But DynamoDB is excellent for specific access patterns:

- **Wallet cache:** Key = wallet address, value = metadata (tier, last seen, cluster ID). High read volume, simple lookups, no JOINs.
- **Price snapshots:** Key = token address + timestamp. Write-heavy, append-only, queried by time range.
- **Session state:** Key = session ID, value = current state. TTL-based expiration.

The exam tests this distinction heavily. The question is always: "Which database service should the company use?" The answer depends on the access pattern, not the data volume.

### Decision tree

```
Is the access pattern relational (JOINs, foreign keys, complex queries)?
  YES → Is storage resilience or 15+ read replicas needed?
    YES → Aurora
    NO  → RDS
  NO  → Is it key-value or document access (lookup by primary key)?
    YES → DynamoDB
    NO  → Is it graph data (relationships between entities)?
      YES → Neptune
      NO  → Is it time-series (metrics, IoT sensor data)?
        YES → Timestream
        NO  → Re-evaluate — one of the above usually fits
```

For Haven: core schema → RDS PostgreSQL. Wallet cache → DynamoDB. That is the architecture we will build in the lab.

---

## The Build

Everything in this section happens in the **lab VPC** (`10.1.0.0/16`). Haven's production VPC (`10.0.0.0/16`) is not touched. The Haven daemon is not touched. We are building a parallel database infrastructure to learn the concepts, then tearing it down.

### Step 0: Set up the lab VPC networking

RDS instances must be placed in a VPC with subnets in at least two Availability Zones (this is an RDS requirement, even for single-AZ deployments). We need private subnets because databases should never be publicly accessible.

```bash
# Create the lab VPC
LAB_VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.1.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=haven-lab-vpc}]' \
  --region us-east-1 \
  --query 'Vpc.VpcId' --output text)
echo "Lab VPC: $LAB_VPC_ID"

# Create two private subnets in different AZs
LAB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id $LAB_VPC_ID \
  --cidr-block 10.1.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-lab-db-a}]' \
  --region us-east-1 \
  --query 'Subnet.SubnetId' --output text)
echo "Subnet A: $LAB_SUBNET_A"

LAB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id $LAB_VPC_ID \
  --cidr-block 10.1.2.0/24 \
  --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-lab-db-b}]' \
  --region us-east-1 \
  --query 'Subnet.SubnetId' --output text)
echo "Subnet B: $LAB_SUBNET_B"

# Create a DB subnet group (RDS requires this)
aws rds create-db-subnet-group \
  --db-subnet-group-name haven-lab-db-subnets \
  --db-subnet-group-description "Lab subnets for RDS exercises" \
  --subnet-ids $LAB_SUBNET_A $LAB_SUBNET_B \
  --region us-east-1

# Create a security group for the RDS instance
LAB_DB_SG=$(aws ec2 create-security-group \
  --group-name haven-lab-db-sg \
  --description "Lab RDS security group" \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1 \
  --query 'GroupId' --output text)
echo "DB Security Group: $LAB_DB_SG"

# Allow PostgreSQL from within the lab VPC
aws ec2 authorize-security-group-ingress \
  --group-id $LAB_DB_SG \
  --protocol tcp --port 5432 \
  --cidr 10.1.0.0/16 \
  --region us-east-1
```

### Step 1: Launch an RDS PostgreSQL instance

```bash
aws rds create-db-instance \
  --db-instance-identifier haven-lab-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15.4 \
  --master-username havenadmin \
  --master-user-password 'LabPassword123!' \
  --allocated-storage 20 \
  --storage-type gp3 \
  --db-subnet-group-name haven-lab-db-subnets \
  --vpc-security-group-ids $LAB_DB_SG \
  --no-publicly-accessible \
  --backup-retention-period 1 \
  --no-multi-az \
  --region us-east-1
```

Now wait. This is the first gotcha — RDS provisioning is not instant:

```bash
# Check status (repeat until 'available')
aws rds describe-db-instances \
  --db-instance-identifier haven-lab-db \
  --region us-east-1 \
  --query 'DBInstances[0].DBInstanceStatus'
```

This will say `creating` for 5-10 minutes. Go get coffee. When it says `available`, grab the endpoint:

```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier haven-lab-db \
  --region us-east-1 \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"
```

The endpoint looks like: `haven-lab-db.cxxxxxxxxx.us-east-1.rds.amazonaws.com`

This is not an IP address. It is a DNS name that resolves to the current primary instance. If you enable Multi-AZ and the primary fails, AWS updates this DNS record to point to the standby. Your application reconnects automatically (after a brief ~60-second failover window). This is why you should always connect by hostname, never by IP.

### Step 2: Create Haven's core tables in PostgreSQL

To interact with the RDS instance, you need a client inside the lab VPC (since we set `--no-publicly-accessible`). Launch a small EC2 instance in the lab VPC as a bastion:

```bash
# Launch a lab bastion instance
LAB_BASTION_SG=$(aws ec2 create-security-group \
  --group-name haven-lab-bastion-sg \
  --description "Lab bastion for DB access" \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1 \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $LAB_BASTION_SG \
  --protocol tcp --port 22 \
  --cidr $(curl -s ifconfig.me)/32 \
  --region us-east-1

# Create internet gateway for bastion SSH access
LAB_IGW=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=haven-lab-igw}]' \
  --region us-east-1 \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $LAB_IGW --vpc-id $LAB_VPC_ID --region us-east-1

# Create a public subnet for the bastion
LAB_SUBNET_PUB=$(aws ec2 create-subnet \
  --vpc-id $LAB_VPC_ID \
  --cidr-block 10.1.10.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-lab-bastion}]' \
  --region us-east-1 \
  --query 'Subnet.SubnetId' --output text)

# Route table for public subnet
LAB_RTB=$(aws ec2 create-route-table \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1 \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $LAB_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $LAB_IGW --region us-east-1
aws ec2 associate-route-table --route-table-id $LAB_RTB --subnet-id $LAB_SUBNET_PUB --region us-east-1

LAB_BASTION=$(aws ec2 run-instances \
  --image-id ami-0c7217cdde317cfec \
  --instance-type t3.micro \
  --key-name haven-key \
  --security-group-ids $LAB_BASTION_SG $LAB_DB_SG \
  --subnet-id $LAB_SUBNET_PUB \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=haven-lab-bastion}]' \
  --region us-east-1 \
  --query 'Instances[0].InstanceId' --output text)
echo "Bastion: $LAB_BASTION"
```

Wait for the bastion to be running, then SSH in and install the PostgreSQL client:

```bash
# Get bastion public IP
BASTION_IP=$(aws ec2 describe-instances \
  --instance-ids $LAB_BASTION \
  --region us-east-1 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

ssh -i ~/.ssh/haven-key.pem ubuntu@$BASTION_IP

# On the bastion:
sudo apt update && sudo apt install -y postgresql-client

# Connect to RDS
psql -h haven-lab-db.cxxxxxxxxx.us-east-1.rds.amazonaws.com \
     -U havenadmin -d postgres
```

Replace the hostname with your actual `$RDS_ENDPOINT`. Enter the password when prompted.

Now create a simplified version of Haven's schema:

```sql
-- Create the haven database
CREATE DATABASE haven;
\c haven

-- Core tables (simplified from Haven's 70-table schema)
CREATE TABLE signals (
    id SERIAL PRIMARY KEY,
    token_address VARCHAR(64) NOT NULL,
    symbol VARCHAR(20),
    score INTEGER,
    lane VARCHAR(10) CHECK (lane IN ('A', 'M', 'S', 'EQ')),
    source VARCHAR(50),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE paper_trades (
    id SERIAL PRIMARY KEY,
    signal_id INTEGER REFERENCES signals(id),
    token_address VARCHAR(64) NOT NULL,
    symbol VARCHAR(20),
    lane VARCHAR(10),
    entry_price DECIMAL(20, 10),
    effective_entry DECIMAL(20, 10),
    current_price DECIMAL(20, 10),
    status VARCHAR(10) DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
    pnl_pct DECIMAL(10, 4),
    entry_time TIMESTAMPTZ DEFAULT NOW(),
    exit_time TIMESTAMPTZ
);

CREATE TABLE alert_history (
    id SERIAL PRIMARY KEY,
    token_address VARCHAR(64) NOT NULL,
    symbol VARCHAR(20),
    alert_type VARCHAR(20),
    lane VARCHAR(10),
    score INTEGER,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE signal_outcomes (
    id SERIAL PRIMARY KEY,
    signal_id INTEGER REFERENCES signals(id),
    horizon VARCHAR(10),
    price_at_signal DECIMAL(20, 10),
    price_at_check DECIMAL(20, 10),
    return_pct DECIMAL(10, 4),
    status VARCHAR(20) DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    checked_at TIMESTAMPTZ
);

-- Insert some sample data
INSERT INTO signals (token_address, symbol, score, lane, source) VALUES
    ('So11111111111111111111111111111111111111112', 'SOL', 82, 'A', 'fast_lane'),
    ('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v', 'USDC', 45, 'M', 'scanner'),
    ('7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU', 'SAMO', 91, 'S', 'lane_s');

INSERT INTO paper_trades (signal_id, token_address, symbol, lane, entry_price, effective_entry, status)
VALUES (1, 'So11111111111111111111111111111111111111112', 'SOL', 'A', 185.50, 187.36, 'OPEN');

-- Verify
SELECT s.symbol, s.score, s.lane, pt.status, pt.entry_price
FROM signals s
LEFT JOIN paper_trades pt ON pt.signal_id = s.id;
```

This demonstrates the key advantage over SQLite: PostgreSQL handles concurrent connections natively. Haven's 34 async loops could each hold a connection pool, and PostgreSQL would serialize writes properly without file-level locking.

Notice the differences from SQLite:

| SQLite | PostgreSQL | Why It Matters |
|--------|-----------|----------------|
| `INTEGER PRIMARY KEY AUTOINCREMENT` | `SERIAL PRIMARY KEY` | Different auto-increment syntax |
| `TEXT` for everything | `VARCHAR`, `TIMESTAMPTZ`, `DECIMAL` | Real types with validation |
| `.get()` doesn't work on Row | Full ORM support | Haven hit this bug 3 times |
| File-level locking | Row-level locking | 34 loops stop fighting |
| No native datetime | `TIMESTAMPTZ` with timezone | No more `isinstance(x, str)` guards |

### Step 3: Create a DynamoDB table for wallet cache

Back on your local machine (DynamoDB does not require VPC placement — it is a fully managed service accessed via API):

```bash
# Create the wallet cache table
aws dynamodb create-table \
  --table-name haven-lab-wallet-cache \
  --attribute-definitions \
    AttributeName=wallet_address,AttributeType=S \
  --key-schema \
    AttributeName=wallet_address,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

That command returns instantly. The table is available in seconds (compared to RDS's 5-10 minutes). This is the DynamoDB advantage — zero provisioning delay.

```bash
# Insert wallet data
aws dynamodb put-item \
  --table-name haven-lab-wallet-cache \
  --item '{
    "wallet_address": {"S": "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"},
    "tier": {"S": "T1"},
    "cluster_id": {"N": "7"},
    "last_seen": {"S": "2026-03-28T14:30:00Z"},
    "win_rate": {"N": "0.42"},
    "total_trades": {"N": "156"}
  }' \
  --region us-east-1

aws dynamodb put-item \
  --table-name haven-lab-wallet-cache \
  --item '{
    "wallet_address": {"S": "DYw8jCTfwHNRJhhmFcbXvVDTqWMEVFBX6ZKUmG5CNSKK"},
    "tier": {"S": "T2"},
    "cluster_id": {"N": "12"},
    "last_seen": {"S": "2026-03-29T09:15:00Z"},
    "win_rate": {"N": "0.38"},
    "total_trades": {"N": "89"}
  }' \
  --region us-east-1

# Query by partition key (this is FAST — single-digit millisecond)
aws dynamodb get-item \
  --table-name haven-lab-wallet-cache \
  --key '{"wallet_address": {"S": "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"}}' \
  --region us-east-1

# Scan the entire table (works for small tables; avoid in production)
aws dynamodb scan \
  --table-name haven-lab-wallet-cache \
  --region us-east-1
```

Notice the access pattern difference. With RDS, you wrote SQL: `SELECT * FROM wallets WHERE address = '...'`. With DynamoDB, you call `get-item` with the exact key. There is no `WHERE` clause, no `LIKE`, no `JOIN`. If you need to find all wallets in cluster 7, you either:

1. Create a Global Secondary Index (GSI) on `cluster_id`, or
2. Scan the entire table and filter client-side (expensive, slow)

This is the DynamoDB tradeoff: blazing-fast key lookups, but you must design your access patterns upfront. If you discover later that you need a new query pattern, you add a GSI (which costs additional read/write capacity).

### Step 4: Compare the two

```bash
# RDS: Complex query — find all open trades with their signal scores
# (Run this from the bastion, connected to psql)
psql -h $RDS_ENDPOINT -U havenadmin -d haven -c "
SELECT pt.symbol, pt.lane, pt.entry_price, pt.status,
       s.score, s.source,
       EXTRACT(EPOCH FROM (NOW() - pt.entry_time)) / 3600 AS hours_open
FROM paper_trades pt
JOIN signals s ON s.id = pt.signal_id
WHERE pt.status = 'OPEN'
ORDER BY s.score DESC;
"

# DynamoDB: Simple lookup — get wallet info by address
# (Fast, simple, but no JOINs possible)
aws dynamodb get-item \
  --table-name haven-lab-wallet-cache \
  --key '{"wallet_address": {"S": "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"}}' \
  --projection-expression "tier, win_rate, total_trades" \
  --region us-east-1
```

The RDS query joins two tables, filters by status, calculates derived columns, and sorts. Try doing that in DynamoDB — you cannot. The DynamoDB query returns one item by its exact key in under 5 milliseconds. Try getting that latency from PostgreSQL — you cannot (network round-trip alone is 1-3ms, plus query parsing, plan generation, and execution).

Different tools for different jobs.

---

## The Teardown

Tear down everything in reverse order. Do not skip this — the RDS instance charges by the hour even when idle.

```bash
# 1. Delete the RDS instance (skip final snapshot for lab)
aws rds delete-db-instance \
  --db-instance-identifier haven-lab-db \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region us-east-1

# Wait for deletion (3-5 minutes)
aws rds describe-db-instances \
  --db-instance-identifier haven-lab-db \
  --region us-east-1 \
  --query 'DBInstances[0].DBInstanceStatus'
# Repeat until you get "DBInstanceNotFound" error (means it's gone)

# 2. Delete the DB subnet group (must wait for RDS to be fully deleted)
aws rds delete-db-subnet-group \
  --db-subnet-group-name haven-lab-db-subnets \
  --region us-east-1

# 3. Delete the DynamoDB table
aws dynamodb delete-table \
  --table-name haven-lab-wallet-cache \
  --region us-east-1

# 4. Terminate the bastion instance
aws ec2 terminate-instances --instance-ids $LAB_BASTION --region us-east-1

# 5. Clean up networking (wait for bastion termination)
aws ec2 delete-security-group --group-id $LAB_BASTION_SG --region us-east-1
aws ec2 delete-security-group --group-id $LAB_DB_SG --region us-east-1
aws ec2 detach-internet-gateway --internet-gateway-id $LAB_IGW --vpc-id $LAB_VPC_ID --region us-east-1
aws ec2 delete-internet-gateway --internet-gateway-id $LAB_IGW --region us-east-1
aws ec2 delete-subnet --subnet-id $LAB_SUBNET_A --region us-east-1
aws ec2 delete-subnet --subnet-id $LAB_SUBNET_B --region us-east-1
aws ec2 delete-subnet --subnet-id $LAB_SUBNET_PUB --region us-east-1
aws ec2 disassociate-route-table --association-id $(aws ec2 describe-route-tables --route-table-ids $LAB_RTB --region us-east-1 --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text) --region us-east-1
aws ec2 delete-route-table --route-table-id $LAB_RTB --region us-east-1
aws ec2 delete-vpc --vpc-id $LAB_VPC_ID --region us-east-1

# 6. Verify nothing is left
aws rds describe-db-instances --region us-east-1 \
  --query 'DBInstances[?DBInstanceIdentifier==`haven-lab-db`]'
aws dynamodb list-tables --region us-east-1 \
  --query 'TableNames[?contains(@, `haven-lab`)]'
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=haven-lab-vpc" \
  --region us-east-1 --query 'Vpcs[*].VpcId'
# All should return empty arrays
```

---

## The Gotcha

### 1. RDS takes 5-10 minutes to launch

DynamoDB tables are available in seconds. RDS instances take 5-10 minutes. Aurora clusters take 10-15 minutes. This is not a bug — AWS is provisioning a real compute instance, attaching storage, configuring networking, initializing the database engine, and running the first backup.

In a lab, this is annoying (you sit there refreshing the status). In production, this matters for disaster recovery planning. If your primary goes down and you need to launch a replacement from a snapshot, your Recovery Time Objective (RTO) includes this provisioning delay. Multi-AZ eliminates this because the standby is already running.

### 2. Multi-AZ doubles the cost

Multi-AZ deploys a synchronous standby instance in a different Availability Zone. You pay for two instances. For `db.t3.micro`, that is ~$13/month single-AZ vs ~$26/month Multi-AZ. For `db.r6g.xlarge`, it is ~$410 vs ~$820.

The exam loves this. "The company wants to minimize costs while maintaining high availability." The answer is usually Multi-AZ for the production database and single-AZ for dev/test. Read replicas are for read scaling, not high availability (they use async replication, so you can lose data during failover).

### 3. DynamoDB on-demand vs provisioned pricing

On-demand mode: you pay per read/write request. Safe for labs, safe for unpredictable workloads. But expensive at scale — a table doing 1,000 writes/second costs ~$475/month on-demand.

Provisioned mode: you commit to a fixed capacity (e.g., 100 read capacity units, 50 write capacity units). Cheaper if your traffic is predictable. But if you exceed the provisioned capacity, requests get throttled (HTTP 400, `ProvisionedThroughputExceededException`).

For the lab, we used `PAY_PER_REQUEST` (on-demand). For Haven in production, the wallet cache does maybe 10 reads/second during scanner cycles and near-zero otherwise. On-demand is correct — the cost would be pennies per month.

### 4. Security group matters more than you think

We set `--no-publicly-accessible` on the RDS instance. This means the instance gets a private IP only — it is not reachable from the internet. You must connect from within the VPC (via the bastion, or via VPC peering from the production VPC).

If you accidentally set `--publicly-accessible` and your security group allows 0.0.0.0/0 on port 5432, your database is open to the internet. Automated scanners will find it within minutes. This is how database breaches happen.

---

## The Result

### What we built

```
Lab VPC (10.1.0.0/16)
  |
  +-- RDS PostgreSQL (db.t3.micro)
  |     - Haven core tables (signals, paper_trades, alert_history, signal_outcomes)
  |     - Private subnet, not publicly accessible
  |     - Automated backups enabled (1-day retention)
  |
  +-- Bastion EC2 (t3.micro)
        - PostgreSQL client
        - SSH access for queries

DynamoDB (no VPC placement)
  |
  +-- haven-lab-wallet-cache
        - Partition key: wallet_address
        - On-demand billing
        - Single-digit ms reads
```

### What Haven's production architecture would look like

```
Production VPC (10.0.0.0/16)
  |
  +-- EC2 (Haven daemon, 34 loops)
  |     - Connects to RDS via private subnet
  |     - Connection pool (asyncpg, 10-20 connections)
  |
  +-- RDS PostgreSQL Multi-AZ (db.t3.small)
  |     - Primary in us-east-1a
  |     - Standby in us-east-1b (automatic failover)
  |     - Read replica for dashboard queries
  |     - 7-day backup retention
  |     - Encrypted at rest (KMS)
  |
  +-- DynamoDB
        - Wallet cache (partition key: wallet_address)
        - Price snapshot cache (partition key: token_address, sort key: timestamp)
        - On-demand billing
```

Migration cost estimate: RDS `db.t3.small` Multi-AZ (~$50/month) + DynamoDB on-demand (~$2/month) = ~$52/month. Current SQLite cost: $0/month but two corruption incidents that cost hours of debugging and a trade that ran +63% with no exit monitoring.

---

## Key Takeaways

1. **SQLite is not wrong, it is limited.** SQLite is the right database for single-process applications, mobile apps, and embedded systems. It is the wrong database for a 34-loop async daemon with concurrent write contention. Know when you have outgrown it.

2. **RDS for relational, DynamoDB for key-value.** This is the most important database decision on the SAA-C03. If the question mentions JOINs, foreign keys, or complex queries, the answer is RDS or Aurora. If it mentions key-value lookups, session state, or "millions of requests per second," the answer is DynamoDB.

3. **Multi-AZ is for availability, Read Replicas are for scaling.** Multi-AZ gives you automatic failover with synchronous replication. Read Replicas give you additional read capacity with asynchronous replication. They solve different problems. You can (and often should) use both.

4. **Always connect to RDS by hostname, never by IP.** The DNS endpoint is what makes failover transparent. If you hardcode the IP, failover works but your application does not reconnect.

5. **DynamoDB access patterns must be designed upfront.** You cannot retroactively add a `WHERE` clause to DynamoDB. If you need a new query pattern, you add a Global Secondary Index. Plan your keys carefully.

6. **Database security is network security.** `--no-publicly-accessible` plus a tight security group is the baseline. A database on the public internet with a weak password is not a risk — it is an inevitability.

---

## Exam Lens

### SAA-C03 Domain Mapping

| Domain | Weight | This Module Covers |
|--------|--------|--------------------|
| Domain 2: Design Resilient Architectures | 26% | Multi-AZ failover, automated backups, read replicas |
| Domain 3: Design High-Performing Architectures | 24% | RDS vs Aurora vs DynamoDB selection, read scaling, partition key design |

### Scenario Questions

**Q1:** A company runs a trading application on EC2 that uses a single SQLite database file. The application has 30 concurrent threads writing to the database. They experience periodic data corruption and need a solution with automatic failover. Which approach should they use?

**A:** Migrate to Amazon RDS with Multi-AZ deployment. RDS handles concurrent connections natively (unlike SQLite's file-level locking), and Multi-AZ provides automatic failover with a synchronous standby. Aurora is also correct but more expensive than needed for this workload.

---

**Q2:** A company needs to store user session data with sub-10ms read latency. The access pattern is always by session ID (primary key). Traffic is unpredictable — it spikes during market hours and drops to near-zero overnight. Which database should they use?

**A:** Amazon DynamoDB with on-demand (PAY_PER_REQUEST) billing. Key-value access by primary key is DynamoDB's sweet spot. On-demand billing handles the traffic spikes without provisioning concerns. RDS would work but adds unnecessary operational overhead for a simple key-value pattern.

---

**Q3:** A company has an RDS PostgreSQL database handling both OLTP writes from their application and heavy read queries from their analytics dashboard. The dashboard queries are causing latency spikes for the application. How should they address this?

**A:** Create a Read Replica and point the dashboard at the replica endpoint. Read Replicas use asynchronous replication and offload read traffic from the primary. Do NOT use Multi-AZ standby for reads — the standby is not accessible for queries (it only activates during failover).

---

**Q4:** A company wants to migrate their on-premises MySQL database to AWS with minimal code changes. They need the database to survive an entire Availability Zone failure without manual intervention. Cost is a secondary concern. Which service should they use?

**A:** Amazon Aurora MySQL. Aurora is MySQL-compatible (minimal code changes), stores data across three AZs automatically (survives AZ failure), and provides automatic failover. RDS Multi-AZ also works but Aurora's storage layer is more resilient. The "cost is secondary" hint points to Aurora over RDS.

---

**Q5:** A company stores IoT sensor readings in DynamoDB with `device_id` as the partition key and `timestamp` as the sort key. They suddenly need to query all readings across all devices for a specific time range. What should they do?

**A:** Create a Global Secondary Index (GSI) with `timestamp` as the partition key (or a synthetic partition like `YYYY-MM-DD` to avoid hot partitions) and `device_id` as the sort key. A full table scan with a filter expression would also work but is expensive and slow for large tables. Alternatively, consider whether Amazon Timestream is a better fit for time-series data.

### Know the Difference

| Concept A | Concept B | Key Distinction |
|-----------|-----------|-----------------|
| **Multi-AZ** | **Read Replicas** | Multi-AZ = synchronous standby for failover (not readable). Read Replica = async copy for read scaling (readable, but can lose data). |
| **RDS** | **Aurora** | RDS = standard engines on EBS. Aurora = custom storage layer, 3-AZ replication, up to 15 read replicas. Aurora costs more but is more resilient. |
| **DynamoDB on-demand** | **DynamoDB provisioned** | On-demand = pay per request, no throttling. Provisioned = fixed capacity, cheaper at steady state, throttled if exceeded. |
| **RDS automated backups** | **RDS snapshots** | Automated = daily, retained 0-35 days, point-in-time recovery. Snapshots = manual, kept until deleted, no PITR. |
| **DynamoDB partition key** | **DynamoDB sort key** | Partition key = determines physical storage location (must be in every query). Sort key = enables range queries within a partition. |
| **RDS Proxy** | **Connection pooling** | RDS Proxy = managed connection pooler for Lambda/serverless (handles connection churn). Application-level pooling = for long-running processes. |

### Cost Traps the Exam Tests

1. **RDS Multi-AZ doubles instance cost.** The standby runs a full instance in another AZ. Dev/test environments should be single-AZ.

2. **RDS storage is billed even when the instance is stopped.** You can stop an RDS instance (no compute charges) but you still pay for the allocated storage and automated backup storage.

3. **DynamoDB on-demand is 5-7x more expensive per request than provisioned** at steady-state traffic. The exam asks "most cost-effective" — if traffic is predictable, provisioned + auto-scaling wins.

4. **Aurora minimum instance is db.t3.medium** (~$50/month). If the question says "minimize cost" and the workload fits `db.t3.micro`, RDS is the answer, not Aurora.

5. **DynamoDB GSIs have their own capacity.** Each GSI consumes additional read/write capacity (on-demand) or requires separate provisioned capacity. A table with 5 GSIs costs significantly more than a table with none.

6. **Cross-region Read Replicas incur data transfer charges.** Same-region replicas are cheaper. The exam might describe a disaster recovery scenario — cross-region replicas are for DR, not cost optimization.

---

**Previous module:** [08 - Operational Dashboards](../08-operational-dashboards/) -- single-pane-of-glass visibility with CloudWatch.

**Next module:** [10 - Serverless Compute](../10-serverless/) -- Lambda functions and API Gateway for event-driven workloads.
