# Module 07: Security Hardening

> **Maps to:** AWS-7 (VID-140) | **Services:** IAM, Security Groups, fail2ban
>
> **Time to complete:** ~45 minutes | **Prerequisites:** Modules 04 (IAM roles), 06 (SSM)

---

## The Problem

Haven is running on EC2 with `AdministratorAccess`.

During the initial setup (Module 01), we created an IAM user called `HavenDev` and attached the `AdministratorAccess` managed policy. This is the AWS equivalent of running everything as root. It was the right call at the time -- we were building VPC networking, creating S3 buckets, configuring CloudWatch alarms, pushing SSM parameters, and managing IAM roles. Every two minutes we needed a different permission. Scoping the policy down during active infrastructure buildout would have meant constant permission errors, policy edits, and wasted time.

But the infrastructure is built now. Haven is running. The 34 async loops are processing market data. The backup cron is writing to S3. The heartbeat is pinging CloudWatch. The secrets are in SSM. The buildout phase is over. The operations phase has begun.

And in the operations phase, `AdministratorAccess` is a liability.

Here is what the `HavenDev` IAM user can currently do:

- Delete every resource in the AWS account
- Create new IAM users with their own admin access
- Read secrets from any SSM path (not just `/haven/*`)
- Modify or delete CloudTrail logs (covering their tracks)
- Launch EC2 instances in any region for crypto mining
- Access any S3 bucket in the account

None of these capabilities are needed for operating Haven. The user needs to manage one EC2 instance, read one S3 bucket, push metrics to CloudWatch, and manage SSM parameters under one path. That is it.

Meanwhile, on the server itself:

- **SSH allows password authentication.** Anyone who guesses the `ubuntu` user's password (or brute-forces it) gets shell access. We use key-based auth, but password auth is still enabled as a fallback.
- **No brute-force protection.** A bot can try thousands of passwords per minute against the SSH port. There is nothing to stop them except the security group (which only allows SSH from one IP, but IPs can be spoofed or change).
- **No OS-level intrusion detection.** If someone does get in, there is no mechanism to detect or block their access.

Security is not a single gate. It is layers. Each layer assumes the layer above it has already been breached.

---

## The Concept

### Defense in depth

The idea is simple: do not rely on any single security control. Stack multiple independent layers so that a failure in one does not compromise the system.

For Haven, the layers are:

| Layer | Control | What It Stops |
|-------|---------|---------------|
| **Network** | Security Group | Blocks all traffic except SSH from one IP |
| **Authentication** | SSH key-only | Blocks password guessing |
| **Intrusion prevention** | fail2ban | Auto-bans IPs after failed SSH attempts |
| **Authorization** | IAM least-privilege | Limits damage if CLI credentials are compromised |
| **Encryption** | SSM SecureString (Module 06) | Protects secrets at rest |
| **Audit** | CloudTrail | Logs all API calls for forensic review |

No single layer is sufficient. Together, they make the system significantly harder to compromise.

### Least privilege

The principle of least privilege says: grant only the permissions needed to do the job, and nothing more. This applies to:

- **IAM users** (your CLI credentials)
- **IAM roles** (what the EC2 instance can do)
- **OS users** (what the `ubuntu` account can access)
- **Network rules** (what ports are open to whom)

Least privilege is annoying during buildout because you keep hitting `AccessDeniedException`. It is essential during operations because it limits blast radius. If credentials leak, the attacker can only do what those credentials allow.

### fail2ban

`fail2ban` is a Linux daemon that monitors log files for patterns (like repeated failed SSH logins) and dynamically adds firewall rules to block offending IPs. It is:

- Free and open source
- Available in the Ubuntu default package repository
- Configurable per-service (SSH, nginx, etc.)
- Battle-tested (20+ years old)

For Haven, we only need the SSH jail. If an IP fails to authenticate 5 times within 10 minutes, it is banned for 10 minutes. This makes brute-force attacks impractical -- the attacker gets 5 guesses every 10 minutes instead of thousands per minute.

---

## The Build

### Step 1: Create the scoped IAM policy

This is the core of the hardening. We need a policy that covers everything Haven operations require and nothing else.

Here is what the `HavenDev` IAM user actually does:

- **EC2**: Start, stop, describe instances (deployments and troubleshooting)
- **S3**: Read the backup bucket (verify backups, download if needed)
- **CloudWatch**: Push metrics, manage alarms, manage dashboards
- **SNS**: Publish to the Haven alerts topic (alarm notifications)
- **SSM**: Read and write parameters under `/haven/*` (secret management)
- **IAM**: Read-only on the Haven EC2 role (verify role config)

Everything is scoped to Haven-specific resources where possible:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Management",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeAddresses",
        "ec2:DescribeVolumes"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-east-1"
        }
      }
    },
    {
      "Sid": "S3BackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::haven-backups-484821991157",
        "arn:aws:s3:::haven-backups-484821991157/*"
      ]
    },
    {
      "Sid": "CloudWatchMetricsAndAlarms",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData",
        "cloudwatch:GetMetricData",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:SetAlarmState",
        "cloudwatch:EnableAlarmActions",
        "cloudwatch:DisableAlarmActions",
        "cloudwatch:PutDashboard",
        "cloudwatch:GetDashboard",
        "cloudwatch:ListDashboards",
        "cloudwatch:DeleteDashboards"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SNSHavenTopic",
      "Effect": "Allow",
      "Action": [
        "sns:Publish",
        "sns:GetTopicAttributes",
        "sns:ListSubscriptionsByTopic"
      ],
      "Resource": "arn:aws:sns:us-east-1:484821991157:haven-alerts"
    },
    {
      "Sid": "SSMHavenParams",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:PutParameter",
        "ssm:DeleteParameter",
        "ssm:DescribeParameters"
      ],
      "Resource": "arn:aws:ssm:us-east-1:484821991157:parameter/haven/*"
    },
    {
      "Sid": "KMSForSSM",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:Encrypt"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "ssm.us-east-1.amazonaws.com"
        }
      }
    },
    {
      "Sid": "IAMReadOnly",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:GetInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::484821991157:role/haven-ec2-role",
        "arn:aws:iam::484821991157:instance-profile/haven-ec2-profile"
      ]
    },
    {
      "Sid": "CloudTrailRead",
      "Effect": "Allow",
      "Action": [
        "cloudtrail:LookupEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

Save this as `haven-dev-scoped.json` and create the policy:

```bash
aws iam create-policy \
  --policy-name haven-dev-scoped \
  --policy-document file://haven-dev-scoped.json
```

### Step 2: Swap the IAM policy

This is the nerve-wracking part. You are removing the policy that lets you do everything and replacing it with one that lets you do only what you need. If you got the scoped policy wrong, your next CLI command will fail.

```bash
# Attach the scoped policy first (belt)
aws iam attach-user-policy \
  --user-name HavenDev \
  --policy-arn arn:aws:iam::484821991157:policy/haven-dev-scoped

# Verify the scoped policy works — try a few commands
aws ec2 describe-instances --region us-east-1 --query "Reservations[0].Instances[0].State"
aws s3 ls haven-backups-484821991157 --region us-east-1
aws ssm get-parameters-by-path --path "/haven/" --region us-east-1 --query "length(Parameters)"

# If all three work, detach AdminAccess (suspenders)
aws iam detach-user-policy \
  --user-name HavenDev \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# Verify AdminAccess is gone
aws iam list-attached-user-policies --user-name HavenDev
```

The output should show only `haven-dev-scoped`. No more `AdministratorAccess`.

### Step 3: Verify with a denied action

Trust but verify. Confirm that actions outside the scoped policy are actually denied:

```bash
# This should fail — we have no Lambda permissions
aws lambda list-functions --region us-east-1
# Expected: AccessDeniedException

# This should fail — we can't create new IAM users
aws iam create-user --user-name test-user
# Expected: AccessDeniedException

# This should fail — we can't read SSM params outside /haven/
aws ssm get-parameter --name "/other/secret" --region us-east-1
# Expected: AccessDeniedException
```

All three should return `AccessDeniedException`. If they succeed, the scoped policy is too broad.

### Step 4: Install and configure fail2ban

```bash
# SSH into the EC2 instance
ssh -i ~/.ssh/haven-key.pem ubuntu@52.5.244.137

# Install fail2ban
sudo apt update && sudo apt install -y fail2ban

# Create the SSH jail configuration
sudo tee /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 600
bantime = 600
EOF
```

Configuration breakdown:

| Setting | Value | Meaning |
|---------|-------|---------|
| `maxretry` | 5 | Ban after 5 failed attempts |
| `findtime` | 600 | Within a 10-minute window |
| `bantime` | 600 | Ban lasts 10 minutes |

These are conservative defaults. For a more aggressive stance, you could set `bantime = 3600` (1 hour) or `bantime = -1` (permanent until manual unban). We chose 10 minutes because Haven's security group already restricts SSH to one IP. fail2ban is a second layer, not the primary defense.

```bash
# Start and enable fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Verify it is running
sudo systemctl status fail2ban

# Check the SSH jail is active
sudo fail2ban-client status sshd
```

Expected output:

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- File list:        /var/log/auth.log
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

### Step 5: Disable SSH password authentication

Ubuntu 24.04 allows both key-based and password-based SSH authentication by default. We only use key-based auth (the `haven-key.pem` from Module 01), so password auth is an unnecessary attack surface.

```bash
# Edit the SSH daemon config
sudo nano /etc/ssh/sshd_config.d/50-cloud-init.conf
```

Find or add these lines:

```
PasswordAuthentication no
ChallengeResponseAuthentication no
```

Then restart SSH. **Important**: do this from an SSH session, and keep the session open. If you break something, you still have an active connection to fix it.

```bash
# Restart SSH — note: it's 'ssh' on Ubuntu 24.04, not 'sshd'
sudo systemctl restart ssh

# Test from a NEW terminal (keep the old one open!)
# This should work (key-based auth):
ssh -i ~/.ssh/haven-key.pem ubuntu@52.5.244.137

# This should fail (password auth):
ssh -o PubkeyAuthentication=no ubuntu@52.5.244.137
# Expected: Permission denied (publickey).
```

If key-based auth works and password auth is rejected, the hardening is complete.

### Step 6: Security group audit

While we are here, verify the security group is still tight:

```bash
aws ec2 describe-security-groups \
  --group-ids sg-063e7aa6735619d68 \
  --region us-east-1 \
  --query "SecurityGroups[0].IpPermissions"
```

You should see exactly one inbound rule: TCP port 22 from your IP. Nothing else. No port 80, no port 443, no 0.0.0.0/0. Haven does not serve web traffic. It makes outbound API calls and sends Telegram messages. It has no reason to accept any inbound traffic except SSH.

If your IP changes (new ISP, new location, VPN), update the security group:

```bash
# Remove old IP
aws ec2 revoke-security-group-ingress \
  --group-id sg-063e7aa6735619d68 \
  --protocol tcp --port 22 \
  --cidr OLD.IP.ADDRESS/32 \
  --region us-east-1

# Add new IP
aws ec2 authorize-security-group-ingress \
  --group-id sg-063e7aa6735619d68 \
  --protocol tcp --port 22 \
  --cidr NEW.IP.ADDRESS/32 \
  --region us-east-1
```

---

## The Gotcha

### 1. The scoped policy was too scoped

The first version of `haven-dev-scoped` did not include `cloudwatch:PutDashboard`. We discovered this in Module 08 when we tried to create the operational dashboard and got:

```
An error occurred (AccessDeniedException) when calling the PutDashboard operation
```

The fix was simple -- add the permission to the policy. But we could not update the policy with the scoped policy itself, because the scoped policy did not include `iam:PutUserPolicy` (correctly -- the operations user should not be able to modify its own permissions).

We had to:

1. Log into the AWS Console (which uses a separate root/admin login)
2. Navigate to IAM > Policies > `haven-dev-scoped`
3. Edit the policy to add `cloudwatch:PutDashboard`
4. Save

Then the CLI worked again.

This is actually the correct pattern. The IAM user for daily operations should NOT be able to modify its own permissions. Policy changes should require a higher-privilege access path (the Console, a separate admin user, or an automation pipeline). This is called **privilege separation**.

The lesson is practical: when you create a scoped policy, you will miss something. That is normal. Keep Console access as your break-glass option. Iterate on the policy as you discover gaps. Each iteration makes the policy more complete and more secure.

### 2. Ubuntu 24.04 SSH service name

Every guide on the internet says to restart SSH with:

```bash
sudo systemctl restart sshd
```

On Ubuntu 24.04, the service is named `ssh`, not `sshd`:

```bash
# This fails
sudo systemctl restart sshd
# Failed to restart sshd.service: Unit sshd.service not found.

# This works
sudo systemctl restart ssh
```

This is a small thing, but it will make your restart command fail. Ubuntu and RHEL/CentOS use different service names. Know which OS you are on.

### 3. The locked-out-of-SSH fear

Disabling password authentication on a remote server is one of those changes where, if you get it wrong, you lose access to the machine. The recovery path (EC2 Instance Connect, serial console, or detaching the EBS volume and mounting it on another instance) is tedious.

The defensive approach:

1. Keep your current SSH session open while making changes
2. Test with a new connection in a separate terminal
3. Only close the original session after confirming the new connection works
4. If something breaks, the original session is still active and you can revert

We did this, and it went smoothly. But the 15 seconds between restarting SSH and confirming the new connection worked were tense.

---

## The Result

### Before

```
IAM User:     AdministratorAccess (can do anything in AWS)
SSH:          Password + key auth (two attack vectors)
Brute-force:  No protection (security group is the only gate)
Audit:        CloudTrail (default, but admin can delete it)
```

### After

```
IAM User:     haven-dev-scoped (8 specific statement blocks, resource-scoped)
SSH:          Key-only auth (password rejected)
Brute-force:  fail2ban (5 attempts → 10 min ban)
Audit:        CloudTrail (admin cannot delete — no IAM self-modification)
Console:      Break-glass only (for policy updates)
```

Verification checklist:

```bash
# 1. IAM — only scoped policy attached
aws iam list-attached-user-policies --user-name HavenDev
# haven-dev-scoped only — no AdministratorAccess

# 2. Denied actions work
aws lambda list-functions --region us-east-1
# AccessDeniedException

# 3. fail2ban is running
ssh -i ~/.ssh/haven-key.pem ubuntu@52.5.244.137 \
  "sudo fail2ban-client status sshd"
# Currently banned: 0, jail active

# 4. Password auth is disabled
ssh -o PubkeyAuthentication=no ubuntu@52.5.244.137
# Permission denied (publickey).

# 5. Security group — SSH from one IP only
aws ec2 describe-security-groups \
  --group-ids sg-063e7aa6735619d68 \
  --region us-east-1 \
  --query "SecurityGroups[0].IpPermissions[*].IpRanges[*].CidrIp"
# [["172.3.171.207/32"]]
```

The system has four independent layers between an attacker and the Haven daemon. Each layer assumes the one above it has been compromised.

---

## Key Takeaways

1. **Start with AdminAccess to build, then lock down before production.** Fighting permissions during infrastructure buildout wastes time. Fighting a breach after going live wastes everything. The transition point is when you stop creating resources and start operating them.

2. **Least-privilege is iterative.** You will discover missing permissions as you use the system. That is expected. Keep a higher-privilege break-glass path (Console access) and refine the scoped policy over time. Each iteration is an improvement.

3. **fail2ban is a 1-minute install with high value.** `apt install fail2ban`, write a 6-line jail config, enable it. You now have automated brute-force protection. The ROI per minute of effort is extraordinary.

4. **Test SSH access after every security change.** Keep your current session open, test from a new terminal. The paranoia is justified -- locking yourself out of a remote server is a bad afternoon.

5. **Keep Console access as break-glass.** The operations IAM user should not be able to modify its own permissions. Policy changes should require a separate, higher-privilege access path. This is privilege separation, and it is a feature, not a limitation.

6. **Know your OS.** `sshd.service` vs `ssh.service`. `yum` vs `apt`. `/var/log/secure` vs `/var/log/auth.log`. Small differences that cause real failures. Always verify service names on your specific distribution.

---

**Previous module:** [06 - Secrets Management](../06-secrets-management/) -- SSM Parameter Store and the startup wrapper pattern.

**Next module:** [08 - Operational Dashboards](../08-operational-dashboards/) -- single-pane-of-glass visibility with CloudWatch.
