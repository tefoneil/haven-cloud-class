#!/bin/bash
# =============================================================================
# Module 01: VPC & Compute — AWS CLI Commands
# Maps to: AWS-1 (VID-134)
# =============================================================================
# These commands create a complete VPC networking stack and launch an EC2
# instance. Run them in order. Each command's output contains IDs that
# subsequent commands need — read the annotations.
#
# Prerequisites:
#   - AWS CLI v2 installed and configured (`aws configure`)
#   - An IAM user with EC2/VPC permissions
#   - Region: us-east-1 (all commands assume this region)
# =============================================================================

# -----------------------------------------------------------
# STEP 1: Create the VPC
# -----------------------------------------------------------
# The VPC is your isolated network. 10.0.0.0/16 gives 65,536 IPs.
# Save the VpcId from the output — every subsequent command needs it.

aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=haven-vpc}]' \
  --region us-east-1

# Example output VpcId: vpc-02e336f3886476d2d

# -----------------------------------------------------------
# STEP 2: Create the Public Subnet
# -----------------------------------------------------------
# Subnets live in a specific Availability Zone. us-east-1a is the default.
# /24 gives 256 addresses — more than enough for a single-instance deployment.

aws ec2 create-subnet \
  --vpc-id vpc-02e336f3886476d2d \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=haven-public-subnet}]' \
  --region us-east-1

# Example output SubnetId: subnet-0c5163c95dd507fc5

# Enable auto-assign public IP — without this, instances get only private IPs
# and you cannot SSH in from the internet.

aws ec2 modify-subnet-attribute \
  --subnet-id subnet-0c5163c95dd507fc5 \
  --map-public-ip-on-launch \
  --region us-east-1

# -----------------------------------------------------------
# STEP 3: Create and Attach the Internet Gateway
# -----------------------------------------------------------
# The IGW connects your VPC to the public internet.
# Without it: no SSH in, no API calls out, no apt update.

aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=haven-igw}]' \
  --region us-east-1

# Example output InternetGatewayId: igw-0d545d2e407ae4843

# Attach the IGW to the VPC. Creating it is not enough — it must be attached.

aws ec2 attach-internet-gateway \
  --internet-gateway-id igw-0d545d2e407ae4843 \
  --vpc-id vpc-02e336f3886476d2d \
  --region us-east-1

# -----------------------------------------------------------
# STEP 4: Create Route Table and Add Default Route
# -----------------------------------------------------------
# The route table tells traffic where to go. We need a route that sends
# all internet-bound traffic (0.0.0.0/0) through the IGW.

aws ec2 create-route-table \
  --vpc-id vpc-02e336f3886476d2d \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=haven-public-rt}]' \
  --region us-east-1

# Example output RouteTableId: rtb-0f7010c02f1080cb6

# Add the default route — this is what makes the subnet "public"

aws ec2 create-route \
  --route-table-id rtb-0f7010c02f1080cb6 \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id igw-0d545d2e407ae4843 \
  --region us-east-1

# Associate the route table with the subnet.
# WARNING: Without this association, the subnet uses the VPC's default
# route table, which has NO route to the IGW. Your instance will silently
# have no internet access.

aws ec2 associate-route-table \
  --route-table-id rtb-0f7010c02f1080cb6 \
  --subnet-id subnet-0c5163c95dd507fc5 \
  --region us-east-1

# -----------------------------------------------------------
# STEP 5: Create the Security Group
# -----------------------------------------------------------
# Security groups are stateful firewalls. Default: deny all inbound,
# allow all outbound. We add one inbound rule: SSH from our home IP.

aws ec2 create-security-group \
  --group-name haven-sg \
  --description "Haven daemon - SSH access" \
  --vpc-id vpc-02e336f3886476d2d \
  --region us-east-1

# Example output GroupId: sg-063e7aa6735619d68

# Allow SSH from your home IP ONLY.
# Replace 172.3.171.207 with YOUR IP (find it: curl -s ifconfig.me)
# The /32 means exactly one IP address. Do NOT use 0.0.0.0/0.

aws ec2 authorize-security-group-ingress \
  --group-id sg-063e7aa6735619d68 \
  --protocol tcp \
  --port 22 \
  --cidr 172.3.171.207/32 \
  --region us-east-1

# -----------------------------------------------------------
# STEP 6: Create the SSH Key Pair
# -----------------------------------------------------------
# AWS generates the key pair. You download the private half.
# The public half stays in AWS and gets injected into the instance.

aws ec2 create-key-pair \
  --key-name haven-key \
  --query 'KeyMaterial' \
  --output text \
  --region us-east-1 > ~/.ssh/haven-key.pem

# MANDATORY: SSH refuses keys with loose permissions.
# Without this, you get: "WARNING: UNPROTECTED PRIVATE KEY FILE"

chmod 400 ~/.ssh/haven-key.pem

# -----------------------------------------------------------
# STEP 7: Launch the EC2 Instance
# -----------------------------------------------------------
# t3.small: 2 vCPU, 2GB RAM — enough for Haven's 34 async loops (~800MB peak)
# AMI: Ubuntu 24.04 LTS in us-east-1 (AMI IDs are region-specific!)
# Disk: 30GB gp3 — accommodates 574MB DB + logs + growth

aws ec2 run-instances \
  --image-id ami-0071174ad8cbb9e17 \
  --instance-type t3.small \
  --key-name haven-key \
  --security-group-ids sg-063e7aa6735619d68 \
  --subnet-id subnet-0c5163c95dd507fc5 \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=haven-daemon}]' \
  --region us-east-1

# Example output InstanceId: i-0901f92161a092f2c

# -----------------------------------------------------------
# STEP 8: Wait for Running State and Get Public IP
# -----------------------------------------------------------
# The instance takes 30-60 seconds to initialize.

aws ec2 wait instance-running \
  --instance-ids i-0901f92161a092f2c \
  --region us-east-1

# Get the public IP address

aws ec2 describe-instances \
  --instance-ids i-0901f92161a092f2c \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region us-east-1

# Example output: 23.22.54.235

# -----------------------------------------------------------
# STEP 9: Connect via SSH
# -----------------------------------------------------------
# The default username for Ubuntu AMIs is 'ubuntu' (not root, not ec2-user).

ssh -i ~/.ssh/haven-key.pem ubuntu@23.22.54.235

# -----------------------------------------------------------
# VERIFICATION COMMANDS (run after connecting)
# -----------------------------------------------------------

# Check OS and kernel
uname -a
# Expected: Linux ... 6.8.0-1021-aws ... x86_64 GNU/Linux

# Check memory (should show ~1.9Gi total)
free -h

# Check disk (should show ~29G, ~8% used)
df -h /

# Check instance metadata (from inside the instance)
curl -s http://169.254.169.254/latest/meta-data/instance-type
# Expected: t3.small

# -----------------------------------------------------------
# UTILITY: Update Security Group IP
# -----------------------------------------------------------
# When your home IP changes, update the security group.
# Step 1: Find your current IP
# Step 2: Revoke the old rule
# Step 3: Add the new rule

# Find current IP
curl -s ifconfig.me

# Revoke old IP (replace with your old IP)
aws ec2 revoke-security-group-ingress \
  --group-id sg-063e7aa6735619d68 \
  --protocol tcp \
  --port 22 \
  --cidr OLD_IP/32 \
  --region us-east-1

# Add new IP (replace with your new IP)
aws ec2 authorize-security-group-ingress \
  --group-id sg-063e7aa6735619d68 \
  --protocol tcp \
  --port 22 \
  --cidr NEW_IP/32 \
  --region us-east-1
