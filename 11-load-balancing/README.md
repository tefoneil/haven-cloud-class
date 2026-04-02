# Module 11: Load Balancing & Auto Scaling — "Haven Dashboard Needs to Scale"

> **Maps to:** SAA-C03 Domains 2, 3 | **Services:** ALB, Auto Scaling Groups, Launch Templates
>
> **Time to complete:** ~50 minutes | **Prerequisites:** Module 01 (VPC, subnets, security groups)

---

## The Problem

Haven has a Streamlit command center dashboard. It displays live system status, paper trade performance, lane metrics, and signal history. Right now it runs on the same t3.small EC2 instance as the daemon:

```bash
streamlit run src/dashboard/command_center.py --server.port 8501
```

This works for one person — Brandon, checking the dashboard from his laptop. But there are problems with this setup that become obvious as soon as you think about what happens next.

**Problem 1: Single point of failure.** The dashboard process shares an instance with the daemon. If the instance fails (hardware issue, AZ outage, accidental termination), both the daemon and the dashboard go down simultaneously. The daemon has recovery procedures (Module 03, Module 05). The dashboard does not. It just disappears.

**Problem 2: Resource contention.** The t3.small has 2 vCPU and 2 GB RAM. The daemon's 34 async loops consume CPU for API calls, database writes, and price monitoring. Streamlit consumes CPU to render charts and serve web requests. When the Lane M scanner kicks off a 5-minute cycle and someone loads the performance dashboard with 115 closed trades, both compete for the same 2 GB of memory. The dashboard renders slowly. The daemon's loops get starved.

**Problem 3: No horizontal scaling.** If a second person wants to use the dashboard — say, a co-developer reviewing paper trade outcomes — they connect to the same Streamlit process on the same instance. Streamlit handles this fine at 2 users. At 10 users, it degrades. At 50, it falls over. There is no mechanism to add capacity.

**Problem 4: No health recovery.** If the Streamlit process crashes (out of memory, unhandled exception, dependency conflict), it stays crashed until someone SSHs in and restarts it. There is no automatic restart, no health check, no replacement.

What if the dashboard ran on its own infrastructure that could automatically recover from failures and scale up when traffic increases?

---

## The Concept

### Application Load Balancer (ALB)

An Application Load Balancer sits in front of your application and distributes incoming HTTP/HTTPS requests across multiple targets (EC2 instances, containers, Lambda functions). It operates at Layer 7 (HTTP), which means it understands HTTP headers, paths, and methods. This enables intelligent routing.

For Haven, the ALB would:

1. Accept HTTPS connections from users
2. Terminate SSL (handle the certificate so the backend does not have to)
3. Health-check the dashboard instances (send a request every 30 seconds, expect a 200 response)
4. Route traffic to healthy instances only
5. Distribute load across multiple instances if needed

**ALB routing capabilities:**

| Rule | Example | Haven Use Case |
|------|---------|----------------|
| Path-based | `/api/*` → API servers, `/*` → web servers | `/dashboard/*` → Streamlit, `/webhook/*` → Lambda |
| Host-based | `api.haven.com` → API, `dash.haven.com` → dashboard | Separate subdomains per service |
| Header-based | `X-Lane: S` → Lane S service | Internal routing by lane type |
| Method-based | `GET` → read replicas, `POST` → primary | Separate read/write backends |

### Network Load Balancer (NLB)

NLB operates at Layer 4 (TCP/UDP). It does not inspect HTTP content — it forwards raw TCP connections. This makes it faster (microsecond latency vs millisecond for ALB) but less intelligent (no path-based routing, no HTTP health checks).

Use NLB when:
- You need extreme performance (millions of requests per second)
- Your protocol is not HTTP (database connections, WebSocket, custom TCP)
- You need a static IP address for the load balancer (ALB uses dynamic IPs behind a DNS name)

For Haven's Streamlit dashboard, ALB is correct. Streamlit speaks HTTP. We need path-based routing. We need HTTP health checks. NLB would work but wastes its strengths.

### Classic Load Balancer (CLB)

CLB is the original AWS load balancer. It operates at both Layer 4 and Layer 7 but with fewer features than ALB or NLB. AWS considers it legacy. New applications should not use it. The exam still tests it — the correct answer is usually "migrate from CLB to ALB."

### Auto Scaling Groups (ASG)

An Auto Scaling Group maintains a fleet of EC2 instances. You define:

- **Minimum**: Never fewer than this many instances (usually 1)
- **Maximum**: Never more than this many instances (cost control)
- **Desired**: How many to run right now (ASG adjusts this based on scaling policies)

When an instance fails a health check, the ASG terminates it and launches a replacement. When a scaling policy triggers (high CPU, high request count), the ASG launches additional instances. When demand drops, it terminates the extras.

The ASG does not know what your application does. It manages EC2 lifecycle. The ALB handles request routing. Together, they provide self-healing and elastic scaling.

### Launch Templates

A Launch Template is a blueprint for EC2 instances. It specifies the AMI, instance type, key pair, security groups, user data script, and other configuration. When the ASG needs to launch a new instance, it uses the Launch Template.

This is the key to automation. The user data script in the Launch Template installs your application, configures it, and starts it. A new instance goes from "blank Ubuntu" to "running Streamlit dashboard" without any manual intervention. The ASG can scale from 1 to 5 instances, and each new instance bootstraps itself identically.

### How they fit together

```
User (browser)
    |
    v
ALB (distributes requests)
    |
    +---> Instance 1 (Streamlit, healthy)
    +---> Instance 2 (Streamlit, healthy)
    +--x  Instance 3 (crashed — ALB stops routing here)
    |
    v
ASG detects Instance 3 failed health check
    → Terminates Instance 3
    → Launches Instance 4 from Launch Template
    → Instance 4 bootstraps, passes health check
    → ALB starts routing to Instance 4
```

Total downtime: the time between Instance 3 failing and Instance 4 passing its health check. Typically 2-5 minutes. No human intervention required.

---

## The Build

Everything in this section happens in the **lab VPC** (`10.1.0.0/16`). Haven's production VPC (`10.0.0.0/16`) is not touched. The Haven daemon is not touched. We are building a standalone dashboard infrastructure to learn ALB, ASG, and Launch Templates, then tearing it down.

### Step 0: Set up the lab VPC

We need public subnets in two AZs (ALB requires at least two), an internet gateway (for the ALB to receive traffic and for instances to download packages), and security groups.

```bash
# Create the lab VPC
LAB_VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.1.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=haven-lab-vpc-lb}]' \
  --region us-east-1 \
  --query 'Vpc.VpcId' --output text)
echo "Lab VPC: $LAB_VPC_ID"

# Enable DNS hostnames (required for ALB)
aws ec2 modify-vpc-attribute \
  --vpc-id $LAB_VPC_ID \
  --enable-dns-hostnames '{"Value": true}' \
  --region us-east-1

# Create public subnets in two AZs
LAB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id $LAB_VPC_ID \
  --cidr-block 10.1.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-lab-pub-a}]' \
  --region us-east-1 \
  --query 'Subnet.SubnetId' --output text)

LAB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id $LAB_VPC_ID \
  --cidr-block 10.1.2.0/24 \
  --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-lab-pub-b}]' \
  --region us-east-1 \
  --query 'Subnet.SubnetId' --output text)

echo "Subnet A: $LAB_SUBNET_A"
echo "Subnet B: $LAB_SUBNET_B"

# Enable auto-assign public IP on both subnets
aws ec2 modify-subnet-attribute \
  --subnet-id $LAB_SUBNET_A \
  --map-public-ip-on-launch \
  --region us-east-1
aws ec2 modify-subnet-attribute \
  --subnet-id $LAB_SUBNET_B \
  --map-public-ip-on-launch \
  --region us-east-1

# Internet gateway
LAB_IGW=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=haven-lab-igw-lb}]' \
  --region us-east-1 \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway \
  --internet-gateway-id $LAB_IGW \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1

# Route table
LAB_RTB=$(aws ec2 create-route-table \
  --vpc-id $LAB_VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=haven-lab-rtb-lb}]' \
  --region us-east-1 \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route \
  --route-table-id $LAB_RTB \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $LAB_IGW \
  --region us-east-1
aws ec2 associate-route-table \
  --route-table-id $LAB_RTB \
  --subnet-id $LAB_SUBNET_A \
  --region us-east-1
aws ec2 associate-route-table \
  --route-table-id $LAB_RTB \
  --subnet-id $LAB_SUBNET_B \
  --region us-east-1

# Security group for the ALB (allows HTTP from anywhere)
ALB_SG=$(aws ec2 create-security-group \
  --group-name haven-lab-alb-sg \
  --description "Lab ALB - HTTP from internet" \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1 \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-1
echo "ALB SG: $ALB_SG"

# Security group for instances (allows HTTP from ALB only)
INSTANCE_SG=$(aws ec2 create-security-group \
  --group-name haven-lab-instance-sg \
  --description "Lab instances - HTTP from ALB only" \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1 \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $INSTANCE_SG \
  --protocol tcp --port 80 \
  --source-group $ALB_SG \
  --region us-east-1
echo "Instance SG: $INSTANCE_SG"
```

Notice the security group design. The ALB accepts HTTP from the internet (`0.0.0.0/0`). The instances accept HTTP only from the ALB security group (`--source-group $ALB_SG`). Users cannot bypass the ALB and hit instances directly. This is the standard pattern.

### Step 1: Create the Launch Template

The user data script installs nginx and creates a simple Haven status page. In production, this would install Python, clone the repo, and start Streamlit. For the lab, nginx is faster to set up and demonstrates the concept.

```bash
# Create the user data script
USER_DATA=$(cat << 'USERDATA' | base64
#!/bin/bash
apt-get update -y
apt-get install -y nginx

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# Create Haven status page
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Haven Dashboard</title>
    <style>
        body { font-family: monospace; background: #1a1a2e; color: #e0e0e0; padding: 40px; }
        .container { max-width: 800px; margin: 0 auto; }
        h1 { color: #00d4aa; border-bottom: 2px solid #00d4aa; padding-bottom: 10px; }
        .card { background: #16213e; border-radius: 8px; padding: 20px; margin: 15px 0; }
        .label { color: #888; }
        .value { color: #00d4aa; font-weight: bold; }
        .status-ok { color: #00d4aa; }
        .lane { display: inline-block; background: #0f3460; padding: 5px 15px; margin: 5px; border-radius: 4px; }
        table { width: 100%; border-collapse: collapse; }
        td { padding: 8px; border-bottom: 1px solid #333; }
        .instance-info { font-size: 0.9em; color: #666; margin-top: 30px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>HAVEN COMMAND CENTER</h1>

        <div class="card">
            <table>
                <tr><td class="label">Daemon Status</td><td class="value status-ok">RUNNING</td></tr>
                <tr><td class="label">Active Loops</td><td class="value">34 / 34</td></tr>
                <tr><td class="label">Uptime</td><td class="value">127.4 hours</td></tr>
                <tr><td class="label">Database</td><td class="value">574 MB (healthy)</td></tr>
            </table>
        </div>

        <div class="card">
            <h3 style="color: #00d4aa; margin-top: 0;">Lane Status</h3>
            <div class="lane">Lane A: 3 open | 41% WR (34 trades)</div>
            <div class="lane">Lane M: 5 open | 22% WR (115 trades)</div>
            <div class="lane">Lane S: 1 open | 33% WR (3 trades)</div>
            <div class="lane">Lane EQ: 2 open | 50% WR (12 trades)</div>
        </div>

        <div class="card">
            <h3 style="color: #00d4aa; margin-top: 0;">Market Context</h3>
            <table>
                <tr><td class="label">Fear & Greed</td><td class="value">42 (Fear)</td></tr>
                <tr><td class="label">BTC Dominance</td><td class="value">54.2%</td></tr>
                <tr><td class="label">Total Market Cap</td><td class="value">\$2,847B</td></tr>
            </table>
        </div>

        <div class="instance-info">
            Served by: ${INSTANCE_ID} | AZ: ${AZ} | IP: ${PRIVATE_IP}<br>
            <em>This line proves load balancing is working — refresh to see different instance IDs.</em>
        </div>
    </div>
</body>
</html>
EOF

# Create a health check endpoint
cat > /var/www/html/health << EOF
{"status": "healthy", "instance": "${INSTANCE_ID}", "az": "${AZ}"}
EOF

systemctl enable nginx
systemctl start nginx
USERDATA
)

# Create the Launch Template
aws ec2 create-launch-template \
  --launch-template-name haven-lab-dashboard-lt \
  --version-description "Haven dashboard v1" \
  --launch-template-data "{
    \"ImageId\": \"ami-0c7217cdde317cfec\",
    \"InstanceType\": \"t3.micro\",
    \"KeyName\": \"haven-key\",
    \"SecurityGroupIds\": [\"$INSTANCE_SG\"],
    \"UserData\": \"$USER_DATA\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"haven-lab-dashboard\"}]
    }]
  }" \
  --region us-east-1

echo "Launch Template created."
```

The user data script does everything needed to go from blank Ubuntu to serving the Haven status page:

1. Install nginx
2. Query the EC2 instance metadata service for the instance ID, AZ, and IP
3. Generate an HTML status page with the instance details embedded
4. Create a `/health` endpoint for the ALB health check
5. Start nginx

When the ASG launches a new instance from this template, it arrives ready to serve traffic in about 90 seconds. No SSH required. No manual configuration. This is what makes auto scaling possible — every instance is identical and self-configuring.

### Step 2: Create the Target Group

The target group tells the ALB where to send traffic and how to health-check the targets.

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name haven-lab-dashboard-tg \
  --protocol HTTP \
  --port 80 \
  --vpc-id $LAB_VPC_ID \
  --target-type instance \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region us-east-1 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "Target Group: $TG_ARN"
```

Health check configuration breakdown:

| Setting | Value | Meaning |
|---------|-------|---------|
| `health-check-path` | `/health` | ALB sends GET requests to this path |
| `health-check-interval-seconds` | 30 | Check every 30 seconds |
| `health-check-timeout-seconds` | 5 | If no response in 5 seconds, count as failed |
| `healthy-threshold-count` | 2 | 2 consecutive passes = healthy |
| `unhealthy-threshold-count` | 3 | 3 consecutive fails = unhealthy |

An instance that crashes will be marked unhealthy after 90 seconds (3 checks x 30 seconds). The ALB stops routing traffic to it immediately. The ASG detects the unhealthy status and replaces the instance.

### Step 3: Create the Application Load Balancer

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name haven-lab-dashboard-alb \
  --subnets $LAB_SUBNET_A $LAB_SUBNET_B \
  --security-groups $ALB_SG \
  --scheme internet-facing \
  --type application \
  --region us-east-1 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
echo "ALB ARN: $ALB_ARN"

# Get the ALB DNS name (this is the URL you access)
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --region us-east-1 \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "Dashboard URL: http://$ALB_DNS"

# Create a listener (forward HTTP:80 to the target group)
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --region us-east-1
```

The ALB is now running. It has a DNS name like `haven-lab-dashboard-alb-1234567890.us-east-1.elb.amazonaws.com`. But it has no targets yet — the target group is empty. Accessing the URL returns a 503 (no healthy targets).

### Step 4: Create the Auto Scaling Group

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name haven-lab-dashboard-asg \
  --launch-template "LaunchTemplateName=haven-lab-dashboard-lt,Version=\$Latest" \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "$LAB_SUBNET_A,$LAB_SUBNET_B" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 120 \
  --region us-east-1
```

Key settings:

| Setting | Value | Why |
|---------|-------|-----|
| `min-size 1` | Always at least 1 instance | Dashboard is always available |
| `max-size 2` | Never more than 2 instances | Cost control for the lab |
| `desired-capacity 1` | Start with 1 instance | Scale up only when needed |
| `health-check-type ELB` | Use ALB health checks, not just EC2 status | Catches application crashes, not just instance failures |
| `health-check-grace-period 120` | Wait 120 seconds before checking health | Gives the instance time to boot and start nginx |

The health check grace period is critical. Without it, the ASG would check the instance's health immediately after launch. The instance is still running the user data script (installing nginx, generating the HTML). The health check fails. The ASG terminates the "unhealthy" instance. A new one launches. Same thing happens. You get a termination loop. 120 seconds gives the instance time to finish bootstrapping.

### Step 5: Verify

Wait about 2 minutes for the instance to launch and pass health checks, then:

```bash
# Check ASG status
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names haven-lab-dashboard-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].{
    Desired: DesiredCapacity,
    Running: length(Instances),
    Instances: Instances[*].{Id: InstanceId, Health: HealthStatus, AZ: AvailabilityZone}
  }'

# Check target group health
aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN \
  --region us-east-1

# Access the dashboard
curl -s http://$ALB_DNS | head -5
curl -s http://$ALB_DNS/health
```

You should see the HTML status page and a healthy JSON response from `/health`. The footer of the page shows which instance served the request. If you had 2 instances, refreshing the page would alternate between them (unless sticky sessions are enabled).

Open `http://$ALB_DNS` in a browser. You see the Haven Command Center status page — dark theme, lane status cards, market context. The footer shows the instance ID and AZ. This page was generated automatically by the user data script on an instance you never SSH'd into.

### Step 6: Test self-healing

Terminate the instance manually and watch the ASG replace it:

```bash
# Find the current instance
CURRENT_INSTANCE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names haven-lab-dashboard-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
echo "Terminating: $CURRENT_INSTANCE"

# Terminate it
aws ec2 terminate-instances \
  --instance-ids $CURRENT_INSTANCE \
  --region us-east-1

# Watch the ASG respond (check every 30 seconds)
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names haven-lab-dashboard-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[*].{Id: InstanceId, State: LifecycleState, Health: HealthStatus}'
```

The sequence:

1. You terminate the instance
2. The ASG detects `InService` count dropped below `min-size` (1)
3. The ASG launches a new instance from the Launch Template
4. The new instance runs the user data script (installs nginx, generates status page)
5. After the health check grace period (120s), the ALB health check passes
6. The ALB starts routing traffic to the new instance
7. `curl http://$ALB_DNS` works again — with a different instance ID in the footer

Total recovery time: ~3 minutes. Zero human intervention. This is self-healing infrastructure.

---

## The Teardown

Order matters. Delete the ASG first (it will terminate its instances), then the ALB, then the networking.

```bash
# 1. Delete the Auto Scaling Group (terminates all managed instances)
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name haven-lab-dashboard-asg \
  --force-delete \
  --region us-east-1

# Wait for instances to terminate (check with describe-auto-scaling-groups
# until it returns empty or "not found")
echo "Waiting for ASG deletion..."
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names haven-lab-dashboard-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances'

# 2. Delete the ALB listener, ALB, and target group
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --region us-east-1 \
  --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 delete-listener --listener-arn $LISTENER_ARN --region us-east-1
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN --region us-east-1

# Wait ~1 minute for ALB to fully deprovision, then delete TG
echo "Waiting for ALB deprovisioning..."
sleep 60
aws elbv2 delete-target-group --target-group-arn $TG_ARN --region us-east-1

# 3. Delete the Launch Template
aws ec2 delete-launch-template \
  --launch-template-name haven-lab-dashboard-lt \
  --region us-east-1

# 4. Clean up networking
aws ec2 delete-security-group --group-id $INSTANCE_SG --region us-east-1
aws ec2 delete-security-group --group-id $ALB_SG --region us-east-1
aws ec2 detach-internet-gateway \
  --internet-gateway-id $LAB_IGW \
  --vpc-id $LAB_VPC_ID \
  --region us-east-1
aws ec2 delete-internet-gateway --internet-gateway-id $LAB_IGW --region us-east-1

# Disassociate and delete route table
for ASSOC in $(aws ec2 describe-route-tables \
  --route-table-ids $LAB_RTB \
  --region us-east-1 \
  --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text); do
  aws ec2 disassociate-route-table --association-id $ASSOC --region us-east-1
done
aws ec2 delete-route-table --route-table-id $LAB_RTB --region us-east-1

aws ec2 delete-subnet --subnet-id $LAB_SUBNET_A --region us-east-1
aws ec2 delete-subnet --subnet-id $LAB_SUBNET_B --region us-east-1
aws ec2 delete-vpc --vpc-id $LAB_VPC_ID --region us-east-1

# 5. Verify nothing remains
aws elbv2 describe-load-balancers --region us-east-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName, `haven-lab`)]'
aws autoscaling describe-auto-scaling-groups --region us-east-1 \
  --query 'AutoScalingGroups[?contains(AutoScalingGroupName, `haven-lab`)]'
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=haven-lab-vpc-lb" \
  --region us-east-1 --query 'Vpcs[*].VpcId'
# All should return empty arrays
```

---

## The Gotcha

### 1. ALB charges by the hour AND by LCU

ALB pricing has two components:
- **Fixed**: ~$0.0225 per hour (~$16.20/month)
- **Variable**: ~$0.008 per LCU-hour (Load Balancer Capacity Unit)

An LCU measures actual usage across four dimensions: new connections, active connections, bandwidth, and rule evaluations. For Haven's dashboard (low traffic), the LCU cost is negligible. The fixed hourly cost is the concern.

For this lab (~30 minutes), the ALB costs about $0.01. Leaving it running overnight costs about $0.54. Leaving it running for a month costs $16.20. This is the most expensive resource in the lab — delete it when you are done.

### 2. Health check grace period prevents boot loops

If `health-check-grace-period` is too short (say, 10 seconds), the ASG will check the instance's health before the user data script finishes. The nginx process is not running yet. The health check fails. The ASG terminates the instance and launches another one. That one also fails its health check. Termination loop.

We set 120 seconds. The user data script takes about 60-90 seconds (apt update + install nginx + generate HTML). The 120-second grace period gives 30-60 seconds of buffer. If your user data script is longer (installing Python, cloning a repo, running database migrations), increase the grace period accordingly.

### 3. ELB health checks vs EC2 health checks

The ASG can use two types of health checks:

| Type | What It Checks | When to Use |
|------|---------------|-------------|
| **EC2** | Is the instance running? (system status, instance status) | Default. Catches hardware failures. |
| **ELB** | Does the ALB health check pass? (HTTP 200 from `/health`) | Better. Catches application crashes. |

We set `--health-check-type ELB`. This means if nginx crashes but the instance is still running, the ASG will replace it. With EC2 health checks only, a crashed nginx would leave the instance running but not serving traffic — the ASG would think everything is fine.

### 4. Cross-zone load balancing

By default, ALB has cross-zone load balancing enabled. This means the ALB distributes traffic evenly across all healthy targets, regardless of which AZ they are in.

Without cross-zone load balancing, each ALB node (one per AZ) only routes to targets in its own AZ. If you have 1 instance in AZ-a and 3 instances in AZ-b, the AZ-a instance gets 50% of traffic (because the AZ-a ALB node sends all its traffic to the one local target). This creates uneven load distribution.

Cross-zone is what you want. The gotcha is that NLB does NOT enable cross-zone by default, and enabling it incurs data transfer charges between AZs.

### 5. Connection draining

When the ASG terminates an instance (scale-in or replacement), the ALB does not immediately cut connections. It enters a "draining" state — existing connections are allowed to complete, but no new connections are routed to the instance. The default draining timeout is 300 seconds (5 minutes).

For Haven's dashboard (stateless HTTP requests), draining could be reduced to 30 seconds. For long-running connections (WebSocket, file uploads), you might increase it. The exam tests this as "deregistration delay."

---

## The Result

### What we built

```
Internet
    |
    v
ALB (haven-lab-dashboard-alb)
  - DNS: haven-lab-dashboard-alb-xxx.us-east-1.elb.amazonaws.com
  - HTTP:80 listener
  - Health check: GET /health every 30s
    |
    v
Target Group (haven-lab-dashboard-tg)
    |
    v
Auto Scaling Group (haven-lab-dashboard-asg)
  - Min: 1, Max: 2, Desired: 1
  - Health check: ELB-based
  - Grace period: 120 seconds
    |
    v
Launch Template (haven-lab-dashboard-lt)
  - t3.micro, Ubuntu
  - User data: install nginx + Haven status page
  - Self-configuring (no SSH needed)
```

### What happened when we tested

1. **Initial launch**: ASG created 1 instance. 90 seconds later, nginx started. 30 seconds after that, the ALB health check passed. Dashboard accessible at the ALB DNS name.

2. **Self-healing test**: We terminated the instance. ASG detected the loss within 30 seconds. New instance launched. 120 seconds later (grace period), health check passed. Dashboard accessible again. Total downtime: ~3 minutes.

3. **The instance footer changed**: Each request showed the new instance's ID and AZ. Proof that the replacement instance was a completely new machine, bootstrapped automatically from the Launch Template.

### What Haven's production architecture would look like

```
Internet
    |
    v
ALB (haven-dashboard-alb)
  - HTTPS:443 (ACM certificate for dashboard.haven.app)
  - Path routing: / → dashboard TG, /api → API TG
  - WAF attached (rate limiting, IP filtering)
    |
    v
ASG (haven-dashboard-asg)
  - Min: 1, Max: 4
  - Target tracking: scale at 70% CPU
  - Instances in private subnets (NAT gateway for outbound)
  - Launch Template installs Streamlit, connects to RDS (Module 09)
```

The daemon stays on its dedicated EC2 instance. It is not behind the ALB. It does not need to scale horizontally — it is a single-process application with 34 async loops. The dashboard is the user-facing component that benefits from load balancing and auto scaling.

---

## Key Takeaways

1. **ALB is for HTTP, NLB is for TCP.** If your application speaks HTTP and you need path-based routing, use ALB. If you need raw TCP forwarding, static IPs, or extreme throughput, use NLB. The exam tests this distinction heavily.

2. **Auto Scaling Groups are about lifecycle, not load balancing.** The ASG launches, monitors, and terminates instances. The ALB distributes traffic. They are complementary but independent. You can have an ASG without an ALB (for batch workers) or an ALB without an ASG (for a fixed set of instances).

3. **The health check grace period prevents boot loops.** Set it longer than your user data script takes to run. When in doubt, go longer — a slightly delayed health check is better than a termination loop.

4. **Use ELB health checks, not EC2 health checks.** EC2 health checks only catch hardware failures. ELB health checks catch application crashes. Always set `--health-check-type ELB` when using an ALB.

5. **Launch Templates make instances disposable.** If every instance can bootstrap itself from scratch via user data, no instance is special. You can terminate any instance at any time and the ASG will replace it identically. This is the foundation of cloud-native operations.

6. **ALB has a fixed hourly cost.** Even with zero traffic, the ALB charges ~$16/month. For a lab, this is the resource most likely to generate an unexpected bill if you forget to delete it.

---

## Exam Lens

### SAA-C03 Domain Mapping

| Domain | Weight | This Module Covers |
|--------|--------|--------------------|
| Domain 2: Design Resilient Architectures | 26% | ASG self-healing, Multi-AZ ALB, health checks, connection draining |
| Domain 3: Design High-Performing Architectures | 24% | ALB vs NLB selection, scaling policies, cross-zone load balancing |

### Scenario Questions

**Q1:** A company runs a web application on a single EC2 instance. They need the application to automatically recover if the instance fails, with minimal downtime. They want to minimize cost. What should they implement?

**A:** Create an Auto Scaling Group with min=1, max=1, desired=1 using a Launch Template. The ASG will detect instance failure and launch a replacement. This is cheaper than running two instances (which Multi-AZ would imply). Adding an ALB with health checks improves detection speed but is not strictly required for the self-healing behavior — the ASG can use EC2 health checks alone.

---

**Q2:** A company's web application receives HTTP traffic and needs to route `/api/*` requests to a set of API servers and `/*` requests to a set of web servers. Both sets run on EC2 instances. Which load balancer should they use?

**A:** Application Load Balancer (ALB) with path-based routing rules. Create two target groups (API servers and web servers). Create ALB listener rules: `/api/*` forwards to the API target group, default action forwards to the web target group. NLB cannot do path-based routing (Layer 4 only). CLB cannot do path-based routing (legacy).

---

**Q3:** A company uses an Auto Scaling Group with a Launch Template. New instances keep getting terminated within 60 seconds of launch. The user data script takes 3 minutes to complete. What is the most likely cause?

**A:** The health check grace period is too short. The ASG is checking instance health before the user data script finishes, finding the application unhealthy (because it is not running yet), and terminating the instance. Fix: increase the `health-check-grace-period` to at least 240 seconds (3 minutes for the script plus buffer). This is a common exam trap.

---

**Q4:** A company needs a load balancer with a static IP address for their application because their clients whitelist IP addresses in their firewall. The application uses HTTP. Which load balancer type should they use?

**A:** Network Load Balancer (NLB). NLB provides static IP addresses (one per AZ, optionally Elastic IPs). ALB uses dynamic IP addresses behind a DNS name — the IPs can change at any time. Even though the application uses HTTP, the static IP requirement makes NLB the correct choice. Alternatively, use AWS Global Accelerator in front of an ALB for static anycast IPs.

---

**Q5:** A company runs an Auto Scaling Group with min=2, max=10. During a traffic spike, the ASG scales to 8 instances. After the spike, it scales back to 2. Users report that their sessions are lost when instances are terminated during scale-in. What should the company do?

**A:** Enable sticky sessions (session affinity) on the ALB target group. This routes a user's requests to the same instance for the duration of their session. However, the better long-term solution is to externalize session state to ElastiCache (Redis) or DynamoDB so that any instance can serve any user. Sticky sessions create uneven load distribution and do not survive instance termination.

### Know the Difference

| Concept A | Concept B | Key Distinction |
|-----------|-----------|-----------------|
| **ALB** | **NLB** | ALB = Layer 7 (HTTP), path/host routing, no static IP. NLB = Layer 4 (TCP/UDP), static IP, higher throughput. |
| **ALB** | **CLB** | CLB = legacy, limited routing. ALB = modern, path/host/header routing. Always prefer ALB for new deployments. |
| **Scaling policy: Target Tracking** | **Scaling policy: Step** | Target tracking = "keep CPU at 50%" (ASG handles the math). Step = "if CPU > 70% add 2, if CPU > 90% add 4" (you define the steps). |
| **Launch Template** | **Launch Configuration** | Launch Configuration = legacy, immutable. Launch Template = current, versioned, supports mixed instance types. Always use Launch Templates. |
| **Health check: EC2** | **Health check: ELB** | EC2 = instance running? (hardware). ELB = application responding? (software). ELB catches more failures. |
| **Cross-zone (ALB)** | **Cross-zone (NLB)** | ALB = enabled by default, no extra charge. NLB = disabled by default, data transfer charges apply when enabled. |
| **Connection draining** | **Deregistration delay** | Same thing, different names. ALB calls it "deregistration delay." Old docs say "connection draining." Default 300 seconds. |
| **Sticky sessions** | **External session store** | Sticky sessions = tie user to one instance (breaks on scale-in). External store (Redis/DynamoDB) = any instance serves any user (survives scaling). |

### Cost Traps the Exam Tests

1. **ALB has a fixed hourly charge.** ~$16/month regardless of traffic. For development environments that sit idle most of the day, this is often the largest cost component. Consider tearing down dev ALBs outside business hours.

2. **Cross-zone load balancing on NLB costs money.** Data transferred between AZs for cross-zone balancing is charged at standard inter-AZ data transfer rates (~$0.01/GB). ALB does not charge for this. If you are cost-optimizing an NLB, consider whether cross-zone is necessary.

3. **ASG does not charge — the instances do.** There is no ASG fee. You pay for the EC2 instances the ASG launches. An ASG with max=10 using m5.xlarge instances can scale to $1,440/month in EC2 charges during a traffic spike. Set max-size carefully.

4. **Over-scaling wastes money, under-scaling loses users.** The exam asks about "cost-effective" scaling. Target tracking policies (e.g., "maintain 50% average CPU") are the simplest and most cost-effective for most workloads. Step scaling gives more control but is harder to tune.

5. **NAT Gateway charges for ASG instances in private subnets.** If your instances need internet access (to download packages in user data, call external APIs), instances in private subnets need a NAT Gateway. NAT Gateway costs $0.045/hour + $0.045/GB. For a lab, use public subnets. For production, budget the NAT Gateway cost.

6. **Unused Elastic IPs cost money.** If you associate an Elastic IP with an NLB and then delete the NLB without releasing the EIP, you pay $0.005/hour for the unused EIP. Always release EIPs after deleting the resource they were attached to.

---

**Previous module:** [10 - Serverless Compute](../10-serverless/) -- Lambda functions and API Gateway for event-driven workloads.

**Next module:** [12 - DNS and CDN](../12-dns-and-cdn/) -- Route 53 and CloudFront for global content delivery.
