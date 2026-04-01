# Haven Cloud Architecture — Final Assessment

> 20 questions covering all modules. Aim for 80% (16/20) to demonstrate mastery.

---

### Networking & Compute (Modules 01-02)

**1.** What is the purpose of a VPC in AWS?
- A) To store files in the cloud
- B) To create an isolated virtual network for your resources
- C) To monitor application performance
- D) To manage user permissions

**2.** A Security Group in AWS is best described as:
- A) A group of IAM users with shared permissions
- B) A stateful virtual firewall that controls inbound and outbound traffic
- C) An encryption standard for S3 buckets
- D) A collection of EC2 instances

**3.** Why do we use a deploy key instead of a personal access token when cloning a repo on EC2?
- A) Deploy keys are faster
- B) Deploy keys grant read-only access to a single repository, limiting blast radius
- C) Personal access tokens don't work on Linux
- D) Deploy keys are required by GitHub

**4.** When transferring a `.env` file to an EC2 instance, the recommended method is:
- A) Commit it to the git repository
- B) Copy-paste through the SSH terminal
- C) SCP (Secure Copy Protocol) directly to the server
- D) Upload it to S3 and download from there

---

### Process Management (Module 03)

**5.** Why is `nohup python app.py &` insufficient for production workloads?
- A) It's slower than systemd
- B) The process won't restart after a crash or server reboot
- C) nohup doesn't work on Ubuntu
- D) It uses too much memory

**6.** In a systemd unit file, `Restart=always` combined with `RestartSec=10` means:
- A) The service restarts every 10 seconds regardless
- B) If the process exits for any reason, systemd waits 10 seconds then restarts it
- C) The service runs for 10 seconds then stops
- D) Logs are rotated every 10 seconds

**7.** What does `PYTHONUNBUFFERED=1` do in a systemd environment?
- A) Increases Python performance by 10%
- B) Forces Python to flush stdout/stderr immediately, so journald captures all output
- C) Disables Python's garbage collector
- D) Enables async mode for the Python interpreter

---

### Storage & Backups (Module 04)

**8.** Why should you use `sqlite3 $DB ".backup $DEST"` instead of `cp` to backup a SQLite database?
- A) `.backup` is faster
- B) `.backup` handles WAL (Write-Ahead Log) mode safely; `cp` can produce a corrupted copy
- C) `cp` doesn't work on binary files
- D) `.backup` compresses the file automatically

**9.** An IAM Instance Profile allows an EC2 instance to:
- A) Connect to the internet
- B) Assume an IAM Role and access AWS services without storing access keys on the machine
- C) Run multiple operating systems simultaneously
- D) Encrypt its EBS volume

**10.** An S3 lifecycle policy with `"Expiration": {"Days": 90}` means:
- A) The bucket is deleted after 90 days
- B) Objects are automatically deleted 90 days after creation
- C) Objects can't be accessed for 90 days
- D) The bucket becomes read-only after 90 days

---

### Monitoring & Alerting (Module 05)

**11.** In CloudWatch, `treat-missing-data=breaching` on an alarm means:
- A) Missing data is ignored
- B) Missing data is treated as if the threshold was breached — the alarm fires
- C) Missing data triggers a reboot
- D) The alarm is disabled when data is missing

**12.** The Haven heartbeat script pushes a custom metric to CloudWatch. What does it report?
- A) CPU temperature
- B) A 1 (running) or 0 (stopped) value based on `systemctl is-active haven-daemon`
- C) The number of active database connections
- D) Network throughput in bytes

---

### Secrets Management (Module 06)

**13.** What is the "startup wrapper" pattern for secrets management?
- A) Encrypting the application binary before deployment
- B) A shell script that fetches secrets from SSM at boot, exports them as env vars, then starts the application
- C) Storing secrets in a Docker container's environment
- D) A Python decorator that loads secrets at function call time

**14.** Why was `LUNARCRUSH_API_KEY` deleted from SSM Parameter Store?
- A) It was a security vulnerability
- B) The subscription was cancelled, so the key was dead — leaving stale secrets creates confusion
- C) SSM has a limit on the number of parameters
- D) It conflicted with another parameter

---

### Security Hardening (Module 07)

**15.** The principle of "least privilege" means:
- A) Using the smallest EC2 instance possible
- B) Granting only the minimum permissions required to perform a task
- C) Running the fewest number of services
- D) Using the cheapest AWS pricing tier

**16.** What happened when the scoped IAM policy was missing `cloudwatch:PutDashboard`?
- A) The dashboard was created with a warning
- B) The AWS CLI command returned AccessDenied, blocking the entire dashboard creation
- C) CloudWatch automatically added the permission
- D) The dashboard was created but couldn't display data

**17.** What does fail2ban do for SSH security?
- A) Encrypts SSH connections with AES-256
- B) Monitors failed login attempts and auto-bans offending IP addresses
- C) Replaces SSH with a more secure protocol
- D) Disables root login

---

### Operational Dashboards (Module 08)

**18.** The Haven-Operations CloudWatch dashboard includes a text widget. What is it used for?
- A) Displaying marketing messages
- B) Quick-reference information: SSH command, log command, backup bucket path
- C) Showing the application source code
- D) Displaying cost estimates

---

### Architecture & Integration

**19.** The total monthly cost of Haven's AWS deployment is approximately:
- A) $5/month
- B) $20/month
- C) $100/month
- D) $500/month

**20.** If the EC2 instance reboots unexpectedly, which components ensure Haven recovers automatically?
- A) S3 + CloudWatch
- B) systemd (auto-restart) + SSM (secrets re-loaded by startup wrapper) + CloudWatch (alarm fires if it doesn't come back)
- C) IAM + Security Groups
- D) VPC + Internet Gateway

---

## Answer Key

1. B | 2. B | 3. B | 4. C | 5. B | 6. B | 7. B | 8. B | 9. B | 10. B
11. B | 12. B | 13. B | 14. B | 15. B | 16. B | 17. B | 18. B | 19. B | 20. B

**Scoring:**
- 18-20: Cloud architect ready
- 15-17: Solid foundation, review missed topics
- 12-14: Re-read modules for missed areas
- Below 12: Start from Module 00 and work through again
