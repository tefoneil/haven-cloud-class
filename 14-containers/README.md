# Module 14: Containers

> What if Haven was packaged into a portable container that runs identically on your Mac, on EC2, and on any other machine with Docker installed?

**Maps to:** SAA-C03 Domains 3, 4 | **Services:** Docker, ECR, ECS, Fargate
**Time to complete:** ~45 minutes
**Prerequisites:** Module 01 (VPC & Compute), Docker installed locally

---

## The Problem

Deploying Haven to EC2 took us most of Module 02. The steps were:

1. SSH into the instance
2. Install Python 3.12 (Ubuntu's default was 3.11)
3. Install Poetry
4. Clone the repo
5. Run `poetry install` (installs 47 dependencies)
6. Copy the `.env` file with 15 API keys
7. Run database migrations
8. Start the daemon with systemd
9. Verify all 34 loops are running

If the instance dies and we need to move to a new server, we repeat all nine steps. If we hire someone to help and they need a dev environment, we write them a setup guide and hope they follow it correctly. When their Mac has SQLite 3.51 and the EC2 instance has SQLite 3.45, we spend an afternoon debugging why a query works locally but fails in production. (This actually happened -- SQLite's `RETURNING` clause behavior differs between versions.)

The root problem is that Haven's deployment is a **procedure**, not a **package**. The procedure has implicit dependencies on the OS, the Python version, the system SQLite version, the Poetry version, and the exact sequence of commands. Any variation in any of these can produce a subtly broken deployment that passes initial checks but fails at 3 AM when a specific code path hits a version-specific behavior.

### What a Container Solves

A container packages the application, its dependencies, its runtime, and its configuration into a single artifact. The Dockerfile is the recipe:

```
Start with Python 3.12 on Debian
Install system dependencies
Copy the application code
Install Python packages
Set environment variables
Define the startup command
```

The resulting image is a snapshot. It runs identically everywhere: your Mac, the EC2 instance, a colleague's Linux laptop, a CI/CD pipeline. The SQLite version is baked in. The Python version is baked in. There is no "works on my machine" because the machine IS the container.

### What a Container Does NOT Solve

Containers are not magic. Haven's architecture has characteristics that make containerization straightforward in some ways and tricky in others:

- **SQLite is a local file.** Containers are ephemeral -- when a container stops, its filesystem is gone. Haven's database needs to survive container restarts. This requires a **volume mount** (bind a host directory into the container).
- **34 async loops in one process.** The daemon is already a single process. A container runs a single process. This is actually a good fit -- one container, one daemon.
- **API keys.** The `.env` file has 15 secrets. You do not bake secrets into images (anyone who pulls the image gets the secrets). Secrets are injected at runtime via environment variables or AWS Secrets Manager.

---

## The Concept

### Docker: Build Once, Run Anywhere

**Docker** is a platform for building, shipping, and running containers. The key abstractions:

| Term | What It Is | Haven Analogy |
|------|-----------|---------------|
| **Dockerfile** | A recipe for building an image | Haven's setup guide, codified |
| **Image** | A read-only template (the built artifact) | A snapshot of Haven + all dependencies |
| **Container** | A running instance of an image | The Haven daemon process |
| **Registry** | A repository for storing images | Where you push images for others to pull |
| **Volume** | Persistent storage attached to a container | Where `haven.db` lives so it survives restarts |

#### The Layered Filesystem

Docker images are built in layers. Each instruction in the Dockerfile creates a layer:

```dockerfile
FROM python:3.12-slim          # Layer 1: Base OS + Python (120MB)
COPY requirements.txt .        # Layer 2: Just the requirements file (1KB)
RUN pip install -r req.txt     # Layer 3: Installed packages (200MB)
COPY src/ /app/src/            # Layer 4: Application code (5MB)
```

Layers are cached. If you change your application code (Layer 4), Docker reuses Layers 1-3 from cache and only rebuilds Layer 4. This is why you copy `requirements.txt` BEFORE copying the application code -- dependencies change rarely, code changes often. If you reversed the order (`COPY . .` then `pip install`), every code change would invalidate the pip install cache.

**Exam note:** Multi-stage builds create smaller images by separating the build environment from the runtime environment. The build stage installs compilers and development tools. The runtime stage copies only the compiled artifacts. Haven's Python dependencies do not need compilation (mostly pure Python), so single-stage is fine. But if you had C extensions to compile, multi-stage would cut the image size significantly.

### ECR: Elastic Container Registry

**ECR** is AWS's Docker registry. It is where you push images so that ECS (or any Docker host) can pull them. Think of it as a private Docker Hub.

Key facts:
- Images are stored in **repositories** (one per application)
- Images are tagged (e.g., `haven:latest`, `haven:v1.2.3`)
- **Lifecycle policies** auto-delete old images to control storage costs
- Pricing: $0.10/GB/month for storage + data transfer charges
- ECR scans images for known vulnerabilities (basic scanning is free)

### ECS: Elastic Container Service

**ECS** is AWS's container orchestration service. It manages running containers -- starting them, stopping them, restarting them when they crash, scaling them up and down. The key abstractions:

| ECS Term | What It Is | Haven Analogy |
|----------|-----------|---------------|
| **Cluster** | A logical grouping of compute resources | "The Haven environment" |
| **Task Definition** | A blueprint for running a container (image, CPU, RAM, env vars) | The systemd unit file, but for containers |
| **Task** | A running instance of a task definition | One running Haven daemon |
| **Service** | Manages desired count of tasks (restarts on failure) | systemd's `restart=always` |

#### ECS Launch Types: EC2 vs Fargate

This is a critical exam concept and a real architectural decision.

| Feature | EC2 Launch Type | Fargate Launch Type |
|---------|----------------|---------------------|
| Infrastructure | You manage EC2 instances | AWS manages compute (serverless) |
| Pricing | EC2 instance cost (24/7) | Per vCPU-second + per GB-second |
| Control | Full OS access, SSH, custom AMIs | No OS access, no SSH |
| Scaling | Must scale EC2 instances + tasks | Just scale tasks |
| Best for | Long-running, steady-state workloads | Variable workloads, burst traffic |
| Haven fit | Better for 24/7 daemon ($15/mo) | More expensive for always-on (~$30/mo) |

**Haven's economics:** The daemon runs 24/7, uses ~100MB RAM and minimal CPU. On EC2 (t3.small), that costs ~$15/month. On Fargate, the equivalent (0.25 vCPU, 0.5GB RAM, 24/7) costs ~$30/month. For a steady-state workload, EC2 launch type wins on cost.

Fargate wins when workloads are intermittent. If Haven only needed to run for 2 hours per day (process signals, generate reports, shut down), Fargate would cost ~$2.50/month vs $15/month for a running EC2 instance.

**Exam shortcut:** "The company wants to minimize operational overhead for running containers" = Fargate. "The company wants to minimize costs for a 24/7 workload" = EC2 launch type (or just EC2 without ECS).

### ECS vs EKS

| Feature | ECS | EKS |
|---------|-----|-----|
| Orchestrator | AWS proprietary | Kubernetes (open source) |
| Learning curve | Lower | Significantly higher |
| Portability | AWS-only | Multi-cloud, on-premises |
| Pricing | Free (pay for compute only) | $0.10/hour for control plane (~$72/mo) |
| Best for | AWS-native shops | Multi-cloud or existing K8s expertise |

**Exam default:** If the question does not mention Kubernetes, the answer is ECS. If it mentions "portability across cloud providers" or "existing Kubernetes expertise," the answer is EKS.

---

## The Build

We build this in two phases: locally (Docker) and in AWS (ECR + ECS). Production Haven is not touched.

### Phase 1: Dockerize Haven Locally

We create a simplified Haven application for containerization. We do not containerize the full 34-loop daemon (that would require the `.env` file with 15 API keys). Instead, we create a minimal app that proves the concepts.

#### Step 1: Create a Minimal Haven App

Create a project directory for the lab:

```bash
mkdir -p ~/haven-container-lab
cd ~/haven-container-lab
```

Create a simplified Haven app (`app.py`):

```python
"""
Simplified Haven daemon for container lab.
Demonstrates: async loops, SQLite, health endpoint.
"""
import asyncio
import sqlite3
import json
import os
from datetime import datetime, timezone
from aiohttp import web

DB_PATH = os.environ.get("HAVEN_DB_PATH", "/data/haven-lab.db")
PORT = int(os.environ.get("PORT", "8080"))

def init_db():
    """Create tables if they don't exist."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS heartbeats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            loop_name TEXT NOT NULL,
            timestamp TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL,
            score INTEGER NOT NULL,
            lane TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    """)
    conn.commit()
    conn.close()
    print(f"Database initialized at {DB_PATH}")

async def heartbeat_loop():
    """Simulates Haven's heartbeat loop -- writes every 30 seconds."""
    while True:
        conn = sqlite3.connect(DB_PATH)
        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "INSERT INTO heartbeats (loop_name, timestamp) VALUES (?, ?)",
            ("heartbeat", now)
        )
        conn.commit()
        conn.close()
        print(f"[{now}] Heartbeat recorded")
        await asyncio.sleep(30)

async def scanner_loop():
    """Simulates Haven's scanner -- generates fake signals every 60 seconds."""
    tokens = ["BONK", "WIF", "POPCAT", "JUP", "RAY"]
    idx = 0
    while True:
        conn = sqlite3.connect(DB_PATH)
        token = tokens[idx % len(tokens)]
        score = 75 + (idx * 3) % 20
        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "INSERT INTO signals (token, score, lane, created_at) VALUES (?, ?, ?, ?)",
            (token, score, "lane_a", now)
        )
        conn.commit()
        conn.close()
        print(f"[{now}] Signal: {token} score={score}")
        idx += 1
        await asyncio.sleep(60)

async def health_handler(request):
    """Health check endpoint for ECS."""
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT timestamp FROM heartbeats ORDER BY id DESC LIMIT 1"
    ).fetchone()
    conn.close()
    status = {
        "status": "healthy",
        "last_heartbeat": row[0] if row else None,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }
    return web.json_response(status)

async def signals_handler(request):
    """Returns recent signals."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT * FROM signals ORDER BY id DESC LIMIT 10"
    ).fetchall()
    conn.close()
    return web.json_response([dict(r) for r in rows])

async def main():
    init_db()

    # Start background loops
    asyncio.create_task(heartbeat_loop())
    asyncio.create_task(scanner_loop())

    # Start web server for health checks
    app = web.Application()
    app.router.add_get("/health", health_handler)
    app.router.add_get("/signals", signals_handler)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", PORT)
    await site.start()
    print(f"Haven Lab daemon running on port {PORT}")

    # Keep running forever
    while True:
        await asyncio.sleep(3600)

if __name__ == "__main__":
    asyncio.run(main())
```

#### Step 2: Write the Dockerfile

```dockerfile
# Dockerfile for Haven Lab
# Demonstrates: single-stage build, non-root user, health check

FROM python:3.12-slim

# Install system dependencies
# SQLite is included in python:3.12-slim, but we pin the version context
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user (security best practice)
RUN useradd --create-home --shell /bin/bash haven

# Set working directory
WORKDIR /app

# Install Python dependencies
# Copy requirements first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Create data directory for SQLite
RUN mkdir -p /data && chown haven:haven /data

# Switch to non-root user
USER haven

# Expose health check port
EXPOSE 8080

# Health check -- ECS uses this to determine container health
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Start the daemon
CMD ["python", "app.py"]
```

Create `requirements.txt`:

```
aiohttp>=3.9.0
```

#### Step 3: Build and Run Locally

```bash
# Build the image
docker build -t haven-lab:latest .

# Run the container with a volume mount for SQLite persistence
docker run -d \
  --name haven-lab \
  -p 8080:8080 \
  -v haven-lab-data:/data \
  -e HAVEN_DB_PATH=/data/haven-lab.db \
  haven-lab:latest

# Check it is running
docker ps

# Check the logs
docker logs haven-lab

# Test the health endpoint
curl http://localhost:8080/health

# Wait 60 seconds, then check signals
curl http://localhost:8080/signals
```

The `-v haven-lab-data:/data` flag creates a Docker volume. The SQLite database lives in this volume. If you stop and remove the container, the volume (and the database) persists. This is how you handle stateful containers.

```bash
# Prove persistence: stop, remove, recreate
docker stop haven-lab && docker rm haven-lab

docker run -d \
  --name haven-lab \
  -p 8080:8080 \
  -v haven-lab-data:/data \
  -e HAVEN_DB_PATH=/data/haven-lab.db \
  haven-lab:latest

# Previous heartbeats and signals are still there:
curl http://localhost:8080/signals
```

#### Step 4: Inspect the Image

```bash
# Check image size
docker images haven-lab

# Output:
# REPOSITORY   TAG      SIZE
# haven-lab    latest   ~180MB

# Compare to the base image:
# python:3.12-slim is ~150MB
# Our app adds ~30MB (aiohttp + its dependencies)

# Inspect layers
docker history haven-lab:latest
```

For comparison, `python:3.12` (non-slim) is ~900MB. Always use `-slim` variants for production images unless you specifically need the full toolchain.

### Phase 2: Push to ECR and Run on ECS

#### Step 5: Create an ECR Repository

```bash
# Create the repository
aws ecr create-repository \
  --repository-name haven-lab \
  --image-scanning-configuration scanOnPush=true \
  --region us-east-1

# Save the repository URI from the output
# Example: 484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab
```

#### Step 6: Push the Image to ECR

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  484821991157.dkr.ecr.us-east-1.amazonaws.com

# Tag the image for ECR
docker tag haven-lab:latest \
  484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab:latest

# Push
docker push \
  484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab:latest
```

#### Step 7: Create an ECS Cluster (Fargate)

```bash
# Create cluster
aws ecs create-cluster \
  --cluster-name haven-lab-cluster \
  --capacity-providers FARGATE \
  --default-capacity-provider-strategy '[{
    "capacityProvider": "FARGATE",
    "weight": 1
  }]'
```

#### Step 8: Create a Task Definition

```bash
# Register the task definition
aws ecs register-task-definition \
  --family haven-lab-task \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" \
  --memory "512" \
  --execution-role-arn arn:aws:iam::484821991157:role/ecsTaskExecutionRole \
  --container-definitions '[{
    "name": "haven-lab",
    "image": "484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab:latest",
    "essential": true,
    "portMappings": [{
      "containerPort": 8080,
      "protocol": "tcp"
    }],
    "environment": [{
      "name": "HAVEN_DB_PATH",
      "value": "/data/haven-lab.db"
    }],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/haven-lab",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
      "interval": 30,
      "timeout": 5,
      "retries": 3,
      "startPeriod": 10
    }
  }]'
```

Configuration notes:
- **`cpu: 256`** = 0.25 vCPU. Haven uses minimal CPU. This is the smallest Fargate allocation.
- **`memory: 512`** = 512MB. Haven uses ~100MB. Smallest Fargate option is 512MB with 0.25 vCPU.
- **`awslogs`** sends container stdout/stderr to CloudWatch Logs. Without this, container logs vanish when the container stops.
- **`execution-role-arn`** is the IAM role ECS uses to pull the image from ECR and write logs. This is NOT the task role (which the application uses for AWS API calls).

Create the CloudWatch log group first:

```bash
aws logs create-log-group --log-group-name /ecs/haven-lab
```

#### Step 9: Run the Task

```bash
# Run a standalone task (not a service -- for lab purposes)
aws ecs run-task \
  --cluster haven-lab-cluster \
  --task-definition haven-lab-task \
  --launch-type FARGATE \
  --network-configuration '{
    "awsvpcConfiguration": {
      "subnets": ["subnet-LABSUBNET"],
      "securityGroups": ["sg-LABSG"],
      "assignPublicIp": "ENABLED"
    }
  }'

# Save the task ARN from the output
```

Replace `subnet-LABSUBNET` and `sg-LABSG` with your lab VPC resources. The security group needs to allow inbound on port 8080.

#### Step 10: Verify the Container is Running

```bash
# Check task status
aws ecs describe-tasks \
  --cluster haven-lab-cluster \
  --tasks arn:aws:ecs:us-east-1:484821991157:task/haven-lab-cluster/TASK_ID \
  --query 'tasks[0].{status:lastStatus,health:healthStatus,ip:containers[0].networkInterfaces[0].privateIpv4Address}'

# Check CloudWatch logs
aws logs get-log-events \
  --log-group-name /ecs/haven-lab \
  --log-stream-name "ecs/haven-lab/TASK_ID" \
  --limit 20 \
  --query 'events[*].message' \
  --output text
```

You should see heartbeat and signal log lines in CloudWatch -- the same output you saw with `docker logs` locally, but now running on Fargate in AWS.

---

## The Teardown

```bash
# Stop the ECS task
aws ecs stop-task \
  --cluster haven-lab-cluster \
  --task arn:aws:ecs:us-east-1:484821991157:task/haven-lab-cluster/TASK_ID

# Delete the ECS cluster (must have no running tasks/services)
aws ecs delete-cluster --cluster haven-lab-cluster

# Delete the ECR repository and all images
aws ecr delete-repository \
  --repository-name haven-lab \
  --force

# Delete the CloudWatch log group
aws logs delete-log-group --log-group-name /ecs/haven-lab

# Clean up local Docker resources
docker stop haven-lab 2>/dev/null; docker rm haven-lab 2>/dev/null
docker rmi haven-lab:latest
docker rmi 484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab:latest
docker volume rm haven-lab-data

# Clean up lab files
rm -rf ~/haven-container-lab
```

Total teardown time: ~2 minutes. No propagation delays (unlike CloudFront).

---

## The Gotcha

### Fargate Is More Expensive Than EC2 for 24/7 Workloads

This is the gotcha that matters for Haven specifically. The math:

**EC2 (t3.small, 24/7):**
- 2 vCPU, 2GB RAM
- ~$15/month (with reserved pricing)
- SSH access, full OS control, can run multiple processes

**Fargate (0.25 vCPU, 0.5GB RAM, 24/7):**
- Per vCPU-hour: $0.04048 x 0.25 x 730 hours = $7.39
- Per GB-hour: $0.004445 x 0.5 x 730 hours = $1.62
- Total: ~$9.01/month for LESS compute than t3.small

That looks close. But Haven actually uses ~800MB peak RAM, so you need 1GB:
- Per GB-hour: $0.004445 x 1.0 x 730 = $3.24
- Total: ~$10.63/month

And if you want equivalent CPU headroom (0.5 vCPU):
- Per vCPU-hour: $0.04048 x 0.5 x 730 = $14.78
- Per GB-hour: $0.004445 x 1.0 x 730 = $3.24
- Total: ~$18.02/month

For LESS compute than a t3.small. And no SSH access. And no volume mounts for SQLite (Fargate does not support EBS volumes natively -- you would need EFS, which adds cost and latency).

**When Fargate wins:** Batch jobs, intermittent processing, auto-scaling workloads. If Haven ran as a batch job (process signals for 2 hours, shut down for 22 hours), Fargate would cost ~$1.20/month.

**When EC2 wins:** Steady-state, 24/7, single-process daemons. Haven is exactly this.

Containers still make sense for Haven on EC2 -- the Docker image eliminates setup drift and makes deployments repeatable. But you would use the ECS EC2 launch type (or just `docker run` on the instance), not Fargate.

### ECR Image Bloat

ECR charges $0.10/GB/month. If you push a 180MB image with every deployment and do not clean up, after 100 deployments you have 18GB of images costing $1.80/month. Not catastrophic, but unnecessary.

**Fix:** ECR lifecycle policies. Set a policy to keep only the last 5 images:

```bash
aws ecr put-lifecycle-policy \
  --repository-name haven-lab \
  --lifecycle-policy-text '{
    "rules": [{
      "rulePriority": 1,
      "description": "Keep last 5 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 5
      },
      "action": { "type": "expire" }
    }]
  }'
```

### Task Role vs Execution Role

This confuses everyone on first encounter and shows up on the exam:

| Role | Who Uses It | What For |
|------|------------|----------|
| **Execution Role** | ECS agent (infrastructure) | Pull images from ECR, write to CloudWatch Logs |
| **Task Role** | Your application code | Call AWS APIs (S3, SQS, Secrets Manager, etc.) |

If Haven's containerized daemon needs to read from Secrets Manager for API keys, the **task role** needs `secretsmanager:GetSecretValue`. The execution role does not. If you put the permission on the execution role, your application cannot access it -- the execution role is used by ECS infrastructure, not by your code.

---

## The Result

After completing this module:

| What We Built | Where | Purpose |
|--------------|-------|---------|
| Dockerfile | Local | Haven's deployment recipe, codified |
| Docker image | Local + ECR | Portable, versioned application artifact |
| ECS cluster | AWS (Fargate) | Container orchestration infrastructure |
| Task definition | AWS | Blueprint for running the containerized daemon |
| Running task | AWS (Fargate) | Haven daemon running in a managed container |
| CloudWatch logs | AWS | Container stdout/stderr captured automatically |

The deployment process changed from a 9-step manual procedure to:

```bash
docker build -t haven-lab:latest .
docker tag haven-lab:latest 484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab:latest
docker push 484821991157.dkr.ecr.us-east-1.amazonaws.com/haven-lab:latest
aws ecs update-service --cluster haven-lab-cluster --service haven-lab-service --force-new-deployment
```

Four commands. No SSH. No "did you install Python 3.12?" No "which Poetry version?" The image is the deployment unit. If it works locally, it works in AWS.

**Cost comparison for Haven:**

| Deployment Method | Monthly Cost | Operational Overhead |
|-------------------|-------------|---------------------|
| EC2 bare metal (current) | ~$15 | SSH + manual updates |
| EC2 + Docker (recommended) | ~$15 | Docker commands, no SSH for deploys |
| ECS Fargate | ~$18-30 | Fully managed, no instance maintenance |
| ECS EC2 launch type | ~$15 + ECS overhead | Container orchestration on your instance |

For Haven's scale (single daemon, one server), **EC2 + Docker** is the sweet spot. You get container portability and repeatable deployments without paying the Fargate premium. ECS Fargate makes sense when you have multiple services, need auto-scaling, or want zero instance management.

---

## Key Takeaways

- **Containers package the application AND its environment.** The Dockerfile is the deployment procedure, codified and version-controlled. "Works on my machine" ceases to be a valid excuse.

- **Docker layer caching is a performance feature you must design for.** Copy dependency files before application code. Put rarely-changing layers early, frequently-changing layers late. A poorly-ordered Dockerfile rebuilds everything on every code change.

- **Fargate is serverless containers, but more expensive for 24/7 workloads.** The exam loves the "minimize operational overhead" keyword (Fargate) vs "minimize cost for steady-state" (EC2). Haven's always-on daemon is a textbook case for EC2 over Fargate.

- **ECS vs EKS: default to ECS unless Kubernetes is mentioned.** ECS is simpler, cheaper ($0 control plane), and sufficient for most AWS-native workloads. EKS costs $72/month for the control plane alone and is justified only for multi-cloud portability or existing Kubernetes expertise.

- **Task role vs execution role is a common exam question.** Execution role = ECS infrastructure (pull images, write logs). Task role = your application (call AWS APIs). They are separate IAM roles with separate permissions.

- **ECR lifecycle policies prevent image bloat.** Set a policy to retain only the last N images. Without it, old images accumulate at $0.10/GB/month.

- **Volumes solve the stateful container problem.** SQLite in a container works only if the database file lives on a volume that persists beyond the container's lifecycle. Fargate supports EFS volumes (not EBS). EC2 launch type supports both EBS and EFS.

---

## Exam Lens

### Scenario Questions You Will See

**Q: A company is migrating a monolithic application to AWS. They want to run it in containers with the LEAST operational overhead. They do not have Kubernetes expertise. Which solution should they use?**

A: **Amazon ECS with Fargate launch type.** "Least operational overhead" = Fargate (no instances to manage). "No Kubernetes expertise" = ECS (not EKS). This is the most straightforward container question on the exam.

**Q: A company runs a container-based application 24/7 with consistent resource usage. They want to minimize costs while using ECS. Which launch type should they choose?**

A: **EC2 launch type** (with Reserved Instances for further savings). Fargate's per-second billing is more expensive than EC2 for steady-state workloads. The "24/7" and "consistent resource usage" keywords point to EC2.

**Q: An ECS task needs to read secrets from AWS Secrets Manager at runtime. Where should the IAM permissions be configured?**

A: On the **task role** (not the execution role). The task role is assumed by the application code running inside the container. The execution role is used by the ECS agent for infrastructure operations (pulling images, writing logs).

**Q: A development team wants to ensure that their container images do not contain known security vulnerabilities before deployment. Which ECR feature should they enable?**

A: **ECR image scanning** (specifically, enhanced scanning with Amazon Inspector for continuous scanning, or basic scanning for on-push). The `scanOnPush: true` flag we set in the build triggers a vulnerability scan each time an image is pushed.

**Q: A company wants to run containers on AWS that can be easily moved to another cloud provider in the future. Which service should they use?**

A: **Amazon EKS.** Kubernetes is cloud-agnostic -- the same manifests, Helm charts, and operators work on GKE (Google), AKS (Azure), and on-premises. ECS is AWS-proprietary. "Portability" = EKS.

**Q: A containerized application logs to stdout. The operations team needs to search and analyze these logs. What is the SIMPLEST way to capture the logs on ECS?**

A: Configure the **awslogs log driver** in the task definition. This sends container stdout/stderr to CloudWatch Logs. No sidecar containers, no log agents, no additional infrastructure.

**Q: A company has an ECR repository with 500 container images consuming 50GB of storage. They only need the last 10 images. How should they reduce storage costs?**

A: Create an **ECR lifecycle policy** that retains only the most recent 10 images and expires the rest. This is automated -- once the policy is set, ECR prunes old images automatically.

**Q: A Dockerized application takes 10 minutes to build because `pip install` runs on every code change, even when dependencies have not changed. How should the Dockerfile be optimized?**

A: **Copy the requirements file and install dependencies BEFORE copying the application code.** Docker layer caching will reuse the dependency layer when only the application code changes. This is the multi-stage/layer-ordering optimization.

### Key Distinctions to Memorize

| Concept | Key Fact |
|---------|----------|
| Fargate pricing | Per vCPU-second + per GB-second, billed from task start to task stop |
| ECS control plane | Free (no cluster management fee) |
| EKS control plane | $0.10/hour (~$72/month) |
| ECR storage | $0.10/GB/month |
| Fargate minimum | 0.25 vCPU + 0.5GB RAM |
| ECS task placement strategies | binpack (cost), spread (availability), random |
| Docker ENTRYPOINT vs CMD | ENTRYPOINT = executable, CMD = default arguments (overridable) |
| Multi-stage builds | Reduce image size by separating build and runtime stages |
| ECS Anywhere | Run ECS tasks on on-premises servers (edge computing) |
| ECR cross-region replication | Replicate images to other regions for DR or latency |

---

Next: [Module 15 - Advanced Security](../15-advanced-security/) -- WAF, Shield, and defense in depth.
