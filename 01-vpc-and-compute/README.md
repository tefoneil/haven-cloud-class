# Module 01: VPC & Compute

> Before you can run code on a server, you need a server. Before you can have a server, you need a network to put it in.

**Maps to:** AWS-1 (VID-134)
**AWS Services:** VPC, EC2, Security Groups, Internet Gateway
**Time to complete:** ~30 minutes

---

## The Problem

Haven needs a server that runs 24/7 with a stable network connection, accessible via SSH for management. The server needs to be isolated -- not sitting on a shared network where other tenants' misconfigured services could interfere. And SSH access must be locked down to a single IP address. This is a crypto trading system; unauthorized access means unauthorized access to trading infrastructure.

The requirements are straightforward:

1. A Linux server with 2+ vCPUs and 2GB+ RAM (the daemon's 34 async loops and SQLite need room)
2. A public IP address for SSH access
3. Network isolation -- our own private network, not a shared one
4. Firewall rules that allow SSH from exactly one IP address and nothing else
5. 30GB of storage for the application, database (574MB and growing), and logs

---

## The Concept

### VPC: Your Private Data Center

A **VPC (Virtual Private Cloud)** is your own isolated section of the AWS network. Think of it as renting a floor in a building. Other AWS customers are on other floors -- they cannot see your network traffic, cannot access your servers, cannot interfere with your routing.

When you create a VPC, you define a **CIDR block** -- the range of private IP addresses available inside it. We use `10.0.0.0/16`, which gives us 65,536 addresses. Far more than we need, but it is the standard starting size and costs nothing extra.

### Subnets: Rooms in Your Data Center

A **subnet** is a subdivision of your VPC, placed in a specific **Availability Zone** (a physically separate data center within a region). Our single subnet `10.0.1.0/24` gives us 256 addresses in `us-east-1a`.

Why does the physical location matter? If you later add a database server, you might put it in a different AZ for redundancy. For Haven, one subnet in one AZ is sufficient -- we have a single EC2 instance and our database is SQLite (local file, not a network service).

### Internet Gateway: The Front Door

By default, a VPC is completely isolated. Nothing goes in, nothing goes out. An **Internet Gateway (IGW)** connects your VPC to the public internet. Without it, your EC2 instance cannot reach the internet (no API calls, no `apt update`) and nobody can reach it (no SSH).

You attach the IGW to the VPC, then create a **route table** entry that says "traffic destined for `0.0.0.0/0` (anywhere on the internet) should go through the IGW." Without this route, your instance has a network card but no directions to the highway.

### Security Groups: The Firewall

A **Security Group** is a stateful firewall attached to your instance. "Stateful" means if you allow inbound SSH traffic, the response packets are automatically allowed out -- you do not need a separate outbound rule for SSH responses.

Our security group allows exactly one thing inbound: SSH (port 22) from a single IP address. Everything else is denied by default. The instance can still make outbound connections (API calls, package downloads) because Security Groups allow all outbound traffic by default.

### EC2: The Computer

**EC2 (Elastic Compute Cloud)** is a virtual server. You pick the operating system, the CPU/RAM configuration, the disk size, and launch it. It runs until you stop it. You pay by the hour.

For Haven:
- **Instance type:** `t3.small` -- 2 vCPUs, 2GB RAM. The daemon uses ~800MB peak, so 2GB gives headroom. `t3.micro` (1GB) was too tight.
- **OS:** Ubuntu 24.04 LTS -- long-term support, familiar package manager, broad community support.
- **Disk:** 30GB gp3 -- the database is 574MB today, plus application code, logs, and growth.

### How It All Fits Together

```
Internet
    |
    v
[Internet Gateway]
    |
    v
[Route Table: 0.0.0.0/0 → IGW]
    |
    v
+---[VPC: 10.0.0.0/16]---------------------------+
|                                                  |
|   +--[Subnet: 10.0.1.0/24, us-east-1a]------+  |
|   |                                           |  |
|   |   +--[Security Group]-----------------+  |  |
|   |   | Allow: SSH (22) from 172.x.x.x/32 |  |  |
|   |   |                                    |  |  |
|   |   |   +--[EC2: t3.small]----------+   |  |  |
|   |   |   | Ubuntu 24.04              |   |  |  |
|   |   |   | 30GB gp3                  |   |  |  |
|   |   |   | Haven Daemon              |   |  |  |
|   |   |   +---------------------------+   |  |  |
|   |   +------------------------------------+  |  |
|   +-------------------------------------------+  |
+--------------------------------------------------+
```

---

## The Build

Every resource is created via AWS CLI. The full command sequence is in [`commands.sh`](commands.sh), annotated with explanations. Here is what we build and why.

### Step 1: Create the VPC

```bash
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=haven-vpc}]' \
  --region us-east-1
```

This creates our isolated network. The `/16` CIDR block is standard -- it gives us room to add subnets later without re-architecting. The `Name` tag makes it findable in the Console.

**Save the VPC ID** from the output (`vpc-02e336f3886476d2d` in our case). Every subsequent resource references it.

### Step 2: Create the Subnet

```bash
aws ec2 create-subnet \
  --vpc-id vpc-02e336f3886476d2d \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-public-subnet}]'
```

Then enable auto-assign public IPs so any instance launched in this subnet gets a public address:

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id subnet-0c5163c95dd507fc5 \
  --map-public-ip-on-launch
```

Without `--map-public-ip-on-launch`, your EC2 instance gets only a private IP (`10.0.1.x`). You would have no way to SSH in from the internet.

### Step 3: Create and Attach the Internet Gateway

```bash
# Create the gateway
aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=haven-igw}]'

# Attach it to the VPC
aws ec2 attach-internet-gateway \
  --internet-gateway-id igw-0d545d2e407ae4843 \
  --vpc-id vpc-02e336f3886476d2d
```

The IGW is useless until attached. A common mistake is creating it and forgetting to attach it -- your instance will appear to be running fine but cannot reach the internet.

### Step 4: Configure Routing

```bash
# Create a route table
aws ec2 create-route-table \
  --vpc-id vpc-02e336f3886476d2d \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=haven-public-rt}]'

# Add a default route to the IGW
aws ec2 create-route \
  --route-table-id rtb-0f7010c02f1080cb6 \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id igw-0d545d2e407ae4843

# Associate the route table with the subnet
aws ec2 associate-route-table \
  --route-table-id rtb-0f7010c02f1080cb6 \
  --subnet-id subnet-0c5163c95dd507fc5
```

Three commands, three things that must all be correct for internet access to work. The VPC has a default route table, but it has no route to the IGW. We create a new route table, add the internet route, and associate it with our subnet.

### Step 5: Create the Security Group

```bash
aws ec2 create-security-group \
  --group-name haven-sg \
  --description "Haven daemon - SSH access" \
  --vpc-id vpc-02e336f3886476d2d

aws ec2 authorize-security-group-ingress \
  --group-id sg-063e7aa6735619d68 \
  --protocol tcp \
  --port 22 \
  --cidr 172.3.171.207/32
```

The `/32` means exactly one IP address. Not a range. Not a subnet. One address. This is the most restrictive SSH access possible -- only connections from your specific home IP are allowed.

### Step 6: Create the Key Pair

```bash
aws ec2 create-key-pair \
  --key-name haven-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/haven-key.pem

chmod 400 ~/.ssh/haven-key.pem
```

This generates an RSA key pair. AWS keeps the public key; you download the private key. The `chmod 400` is not optional -- SSH will refuse to use a key file with loose permissions. You will get a `UNPROTECTED PRIVATE KEY FILE` error and wonder why your perfectly valid key does not work.

### Step 7: Launch the EC2 Instance

```bash
aws ec2 run-instances \
  --image-id ami-0071174ad8cbb9e17 \
  --instance-type t3.small \
  --key-name haven-key \
  --security-group-ids sg-063e7aa6735619d68 \
  --subnet-id subnet-0c5163c95dd507fc5 \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=haven-daemon}]'
```

The AMI (`ami-0071174ad8cbb9e17`) is Ubuntu 24.04 LTS in us-east-1. AMI IDs are region-specific -- this exact ID will not work in us-west-2.

### Step 8: Connect

```bash
ssh -i ~/.ssh/haven-key.pem ubuntu@23.22.54.235
```

If this works, you have a server. You are sitting at a command prompt on a machine in an AWS data center in Virginia. It will not go to sleep. It will not run Chrome. It exists to run your code.

---

## The Gotcha

The security group was configured with a `/32` CIDR -- Brandon's home IP at the time of setup: `172.3.171.207/32`. This is exactly correct from a security standpoint. It is also fragile.

Most residential ISPs assign dynamic IP addresses. They change. Maybe daily, maybe weekly, maybe when your router reboots. When the IP changed, SSH was locked out. The instance was running fine -- the daemon was healthy, all 34 loops were active -- but there was no way to connect to it.

The fix was straightforward: log into the AWS Console (which is accessed via browser, not SSH), find the security group, and update the ingress rule to the new IP. It took 2 minutes. But it was a jarring reminder that "locked down to one IP" means exactly that -- including locking YOU out when that IP changes.

**Mitigations to consider:**

- Check your IP before critical maintenance: `curl -s ifconfig.me`
- Keep the AWS Console bookmarked -- it is your emergency backdoor for security group changes
- For more stable access, consider a VPN with a static IP or AWS Systems Manager Session Manager (which we set up in Module 06)
- Never use `0.0.0.0/0` for SSH. The convenience is not worth the exposure. Bots scan for open SSH ports within minutes of an instance launching.

---

## The Result

After completing all eight steps:

```bash
# Verify the instance is running
aws ec2 describe-instances \
  --instance-ids i-0901f92161a092f2c \
  --query 'Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress,Type:InstanceType}'

# Output:
{
    "State": "running",
    "IP": "23.22.54.235",
    "Type": "t3.small"
}
```

```bash
# SSH in and verify the OS
ssh -i ~/.ssh/haven-key.pem ubuntu@23.22.54.235 "uname -a && free -h && df -h /"

# Output:
Linux ip-10-0-1-x 6.8.0-1021-aws x86_64 GNU/Linux
              total        used        free
Mem:          1.9Gi       180Mi       1.5Gi
Filesystem    Size  Used Avail Use%
/dev/xvda1     29G  2.1G   27G   8%
```

A fresh Ubuntu 24.04 server with 1.9GB usable RAM and 27GB free disk. Running in a VPC with SSH access from a single IP. No GUI, no desktop environment, no wasted resources. Ready for the application.

### AWS Resources Created

| Resource | ID | Purpose |
|----------|-----|---------|
| VPC | `vpc-02e336f3886476d2d` | Isolated network (10.0.0.0/16) |
| Subnet | `subnet-0c5163c95dd507fc5` | Public subnet (10.0.1.0/24, us-east-1a) |
| Internet Gateway | `igw-0d545d2e407ae4843` | Internet access for the VPC |
| Route Table | `rtb-0f7010c02f1080cb6` | Routes traffic to the IGW |
| Security Group | `sg-063e7aa6735619d68` | SSH from home IP only |
| Key Pair | `haven-key` | SSH authentication |
| EC2 Instance | `i-0901f92161a092f2c` | t3.small, Ubuntu 24.04, 30GB gp3 |

**Monthly cost for this module:** ~$17.40 (EC2 + EBS). No Elastic IP yet -- that comes in Module 03.

---

## Key Takeaways

- **A VPC isolates your resources.** It is your own private network within AWS. Other customers cannot see your traffic or access your instances. Always create a VPC for production workloads -- do not use the default VPC.

- **Security Groups are stateful firewalls.** Allow inbound SSH and the responses flow out automatically. Default deny on inbound, default allow on outbound. Use `/32` CIDR for SSH access -- restrict to your exact IP.

- **t3.small (2 vCPU, 2GB RAM) is plenty for a Python daemon.** Haven's 34 async loops, SQLite database, and all API integrations use ~800MB peak. Do not over-provision -- you can resize later with a stop/start cycle.

- **Always use key-based SSH, never passwords.** Password authentication is brute-forceable. Key-based authentication is not (in practice). The `chmod 400` on the key file is mandatory, not a suggestion.

- **The Internet Gateway + Route Table + Subnet association is a three-part chain.** Miss any one piece and your instance silently has no internet access. It will look healthy in the Console but `apt update` will time out and you will spend 30 minutes debugging before realizing you forgot the route table association.

- **AMI IDs are region-specific.** `ami-0071174ad8cbb9e17` is Ubuntu 24.04 in us-east-1. If you deploy in a different region, look up the correct AMI for that region.

---

Next: [Module 02 - Application Deployment](../02-application-deployment/) -- Getting the code running on the server.
