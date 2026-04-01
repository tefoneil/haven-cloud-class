# Module 06: Secrets Management

> **Maps to:** AWS-6 (VID-139) | **Services:** SSM Parameter Store, KMS, IAM
>
> **Time to complete:** ~30 minutes | **Prerequisites:** Modules 03 (systemd) and 04 (IAM roles)

---

## The Problem

Haven's `.env` file is a liability.

Thirty API keys live in a single plaintext file on the EC2 instance: Helius (on-chain data), Telegram Bot API (alerting), CoinGecko Pro (price feeds), Alpaca (equities trading), Chainstack (Solana RPC), OpenAI (analysis), CryptoPanic (news), and two dozen more. Each one is a credential that, if leaked, could drain API quotas, expose trading positions, or send unauthorized messages through the alert bot.

During the initial migration (Module 02), we SCP'd the `.env` from the MacBook to the EC2 instance:

```bash
scp -i ~/.ssh/haven-key.pem .env ubuntu@52.5.244.137:/home/ubuntu/haven/.env
```

That was fine for "does it start?" testing. It is not fine for production.

Here is the threat model:

1. **Disk compromise.** If someone gains read access to the EC2 filesystem (exploit, misconfigured backup, snapshot leak), every API key is exposed in one file.
2. **Process leak.** Environment variables loaded from `.env` are visible in `/proc/<pid>/environ` to anyone with the right permissions on the host.
3. **Accidental exposure.** A misplaced `git add .env` commits everything to version history. A careless `cat .env` in a screen-share exposes keys live.
4. **No audit trail.** There is no record of who read the `.env` or when. No way to know if keys were accessed.

The first three problems share a root cause: secrets are stored as plaintext on disk. The fourth is about visibility. AWS SSM Parameter Store solves both.

---

## The Concept

**AWS Systems Manager Parameter Store** is an encrypted key-value store for configuration data and secrets. It is not a database. It is not a file system. It is a purpose-built service for storing things like API keys, database connection strings, and configuration values that should never live in plaintext on a server.

### How it works

You store a parameter with a name, a type, and a value:

```
Name:  /haven/HELIUS_API_KEY
Type:  SecureString
Value: hsk_abc123... (encrypted at rest with KMS)
```

When your application needs the value, it calls the SSM API to retrieve it. The API call is authenticated via IAM (the EC2 instance's role), encrypted in transit (HTTPS), and logged in CloudTrail.

### Parameter types

| Type | Encryption | Use Case |
|------|-----------|----------|
| `String` | None | Non-sensitive config (region, log level) |
| `StringList` | None | Comma-separated lists |
| `SecureString` | KMS (AES-256) | **API keys, tokens, passwords** |

For Haven, every parameter is a `SecureString`. There is no config value among these 30 that we would want exposed.

### The startup wrapper pattern

The daemon does not call SSM directly. Instead, a shell script runs before the daemon starts:

1. Script calls SSM to fetch all parameters under `/haven/*`
2. Script exports each parameter as an environment variable
3. Script `exec`s the daemon process, replacing itself

The daemon code stays unchanged. It still reads `os.environ["HELIUS_API_KEY"]` the same way it did when the `.env` file existed. The difference is that the value was injected from SSM instead of read from disk.

This pattern has a name in infrastructure circles: **sidecar injection**. The security improvement is real, and the application code does not need to know about it.

### Pricing

SSM Parameter Store standard parameters are free. You can store up to 10,000 parameters at no cost. API calls cost $0.05 per 10,000 requests. Haven calls it once at startup. The cost is literally zero.

---

## The Build

### Step 1: Push secrets to SSM

For each environment variable in the `.env` file, create a SecureString parameter in SSM under the `/haven/` prefix. This groups all Haven secrets together and makes them easy to manage.

```bash
# Push a single secret
aws ssm put-parameter \
  --name "/haven/HELIUS_API_KEY" \
  --type "SecureString" \
  --value "hsk_abc123def456..." \
  --region us-east-1

# Verify it's stored (value will be masked)
aws ssm get-parameter \
  --name "/haven/HELIUS_API_KEY" \
  --region us-east-1

# Verify you can decrypt it
aws ssm get-parameter \
  --name "/haven/HELIUS_API_KEY" \
  --with-decryption \
  --region us-east-1
```

For 30 secrets, this is tedious one-by-one. Here is the batch approach we actually used — read the `.env` file and push each line:

```bash
# Push all .env vars to SSM in one pass
while IFS='=' read -r key value; do
  # Skip comments and blank lines
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
  # Strip surrounding quotes from value
  value=$(echo "$value" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
  echo "Pushing /haven/$key..."
  aws ssm put-parameter \
    --name "/haven/$key" \
    --type "SecureString" \
    --value "$value" \
    --overwrite \
    --region us-east-1
done < .env
```

After running this, verify the count:

```bash
aws ssm get-parameters-by-path \
  --path "/haven/" \
  --region us-east-1 \
  --query "Parameters[].Name" \
  --output table
```

You should see all 30 parameter names listed.

### Step 2: Grant EC2 permission to read SSM

The EC2 instance runs under an IAM role (`haven-ec2-role`, created in Module 04 for S3 backups). That role needs SSM read permission scoped to the `/haven/*` path only.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "arn:aws:ssm:us-east-1:484821991157:parameter/haven/*"
    },
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "ssm.us-east-1.amazonaws.com"
        }
      }
    }
  ]
}
```

Note the `kms:Decrypt` permission. SecureString parameters are encrypted with KMS. The EC2 role needs permission to decrypt, but only when the decryption request comes through SSM. The `Condition` block ensures this role cannot use the KMS key for anything else.

```bash
# Attach the policy to the EC2 role
aws iam put-role-policy \
  --role-name haven-ec2-role \
  --policy-name haven-ssm-read \
  --policy-document file://ssm-read-policy.json
```

### Step 3: Write the startup wrapper

This is the script that bridges SSM and the daemon. It runs before the daemon starts, fetches all secrets, exports them as environment variables, and then `exec`s the daemon.

See `startup-wrapper.sh` in this module directory for the annotated version.

The core logic:

```bash
#!/bin/bash
set -euo pipefail

REGION="us-east-1"
SSM_PATH="/haven/"
VENV_PYTHON="/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12/bin/python"

# Fetch all parameters, decrypt SecureStrings
PARAMS=$(aws ssm get-parameters-by-path \
  --path "$SSM_PATH" \
  --with-decryption \
  --region "$REGION" \
  --query "Parameters[*].{Name:Name,Value:Value}" \
  --output json)

# Export each parameter as an environment variable
# /haven/HELIUS_API_KEY → HELIUS_API_KEY=<value>
eval $(echo "$PARAMS" | python3 -c "
import sys, json
params = json.loads(sys.stdin.read())
for p in params:
    key = p['Name'].split('/')[-1]
    val = p['Value'].replace(\"'\", \"'\\''\")
    print(f\"export {key}='{val}'\")
")

# Replace this process with the daemon
exec $VENV_PYTHON -m src.automation.haven_daemon
```

The `exec` at the end is important. It replaces the shell process with the Python process. Systemd sees one PID, not a parent shell and a child Python process. Signals (SIGTERM for graceful shutdown) go directly to the daemon.

### Step 4: Update systemd to use the wrapper

The systemd unit file from Module 03 originally called Python directly:

```ini
ExecStart=/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12/bin/python \
  -m src.automation.haven_daemon
```

Change it to call the wrapper:

```ini
ExecStart=/home/ubuntu/haven/start-daemon.sh
```

```bash
# Copy wrapper to server
scp -i ~/.ssh/haven-key.pem start-daemon.sh ubuntu@52.5.244.137:/home/ubuntu/haven/
ssh -i ~/.ssh/haven-key.pem ubuntu@52.5.244.137 "chmod +x /home/ubuntu/haven/start-daemon.sh"

# Update the service file
sudo systemctl daemon-reload
sudo systemctl restart haven-daemon
```

### Step 5: Remove the .env file from disk

This is the moment of truth. If the wrapper works, the `.env` is redundant.

```bash
# Keep a backup — just in case
mv /home/ubuntu/haven/.env /home/ubuntu/haven/.env.bak-pre-ssm

# Restart the daemon to prove it works without .env
sudo systemctl restart haven-daemon

# Check it started
sudo journalctl -u haven-daemon --no-pager -n 20
```

If the daemon starts and all 34 loops register, the migration is complete. The `.env.bak-pre-ssm` file stays as an emergency fallback, but it should never be needed again.

### Step 6: Verify the audit trail

Every SSM API call is logged in CloudTrail. You can verify:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetParametersByPath \
  --region us-east-1 \
  --max-results 5
```

This shows who fetched secrets, when, and from where. Something the `.env` file could never provide.

---

## The Gotcha

Three things bit us during this migration.

### 1. IAM propagation delay

After attaching the SSM read policy to the EC2 role, we immediately tried to start the daemon. It failed:

```
botocore.exceptions.ClientError: An error occurred (AccessDeniedException)
when calling the GetParametersByPath operation:
User: arn:aws:sts::484821991157:assumed-role/haven-ec2-role/i-0901f92161a092f2c
is not authorized to perform: ssm:GetParametersByPath
```

IAM policy changes are eventually consistent. "Eventually" in practice means 10 to 30 seconds, but it can be longer. We waited 30 seconds, tried again, and it worked.

This is not a bug. This is how IAM works. AWS documentation acknowledges it. The fix is patience, or a retry loop in the wrapper script (we chose patience).

### 2. Special characters in API keys

The startup wrapper uses `eval` to export variables. This is inherently fragile. One of our API keys contained a single quote character. The naive export:

```bash
export API_KEY='sk_abc'def'
```

...breaks the shell. The `eval` interprets the quotes wrong and either truncates the value or errors out.

The fix is in the Python helper inside the wrapper. It escapes single quotes in values:

```python
val = p['Value'].replace("'", "'\\''")
```

This produces the shell-safe form:

```bash
export API_KEY='sk_abc'\''def'
```

If you have keys with dollar signs, backticks, or backslashes, you will hit similar problems. The Python-based export approach handles these better than pure bash string manipulation, which is why we use it.

### 3. Stale secrets after API decommission

Two weeks after the SSM migration, we cut the BirdEye API integration (PE-229 -- a $30/month savings). We removed the code, removed the import, removed the tests. But we forgot to remove `BIRDEYE_API_KEY` from SSM.

The daemon still loaded it. No error, no crash. Just a dead environment variable taking up space and creating a false impression that BirdEye was still in use.

We caught it during the security audit (Module 07) and deleted it:

```bash
aws ssm delete-parameter --name "/haven/BIRDEYE_API_KEY" --region us-east-1
```

The lesson: secrets management is not "set and forget." When you decommission a service, delete its secrets. Otherwise your parameter store becomes a graveyard of dead credentials -- any one of which could be a liability if leaked.

### 4. The pagination trap (one we dodged)

`get-parameters-by-path` returns at most 10 results per page by default. With 30 parameters, you need to handle pagination or pass `--max-items`. We used the `--query` flag with `--output json`, which handles pagination automatically in the AWS CLI. But if you are calling the API directly (e.g., from boto3), you need to loop on `NextToken` or you will silently get only the first 10 secrets.

Haven has 30 parameters. The first time we ran the wrapper without pagination handling, the daemon started but 20 API integrations silently failed. The CoinGecko price feed, the CryptoPanic news feed, the Alpaca equities connection -- all dead. The daemon did not crash because each integration handles missing credentials gracefully (logs a warning and disables itself). But it was running at 30% capability.

We added `--recursive` to the CLI call, which handles pagination:

```bash
aws ssm get-parameters-by-path \
  --path "$SSM_PATH" \
  --with-decryption \
  --recursive \
  --region "$REGION" \
  ...
```

---

## The Result

Before and after:

| Aspect | Before (`.env`) | After (SSM) |
|--------|-----------------|-------------|
| Storage | Plaintext on disk | Encrypted at rest (KMS AES-256) |
| Access control | Linux file permissions | IAM role + resource-scoped policy |
| Audit trail | None | CloudTrail logs every read |
| Rotation | Edit file, restart daemon | `aws ssm put-parameter --overwrite`, restart daemon |
| Blast radius | All 30 keys in one file | Individual parameters, individually scoped |
| Cost | Free | Free (standard parameters) |

Verification that it works:

```bash
# Daemon starts clean via SSM
$ sudo systemctl status haven-daemon
● haven-daemon.service - Haven Crypto Intelligence Daemon
     Active: active (running) since ...
     ...

# No .env on disk
$ ls -la /home/ubuntu/haven/.env
ls: cannot access '/home/ubuntu/haven/.env': No such file or directory

# SSM has all 30 params
$ aws ssm get-parameters-by-path --path "/haven/" --region us-east-1 \
    --query "length(Parameters)"
30

# CloudTrail shows the fetch
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=GetParametersByPath \
    --region us-east-1 --max-results 1 \
    --query "Events[0].EventTime"
"2026-03-15T..."
```

Zero plaintext secrets on disk. All 34 daemon loops start. Every secret access is logged.

---

## Key Takeaways

1. **Never store secrets in plaintext on servers.** A `.env` file is a single point of compromise. SSM Parameter Store encrypts at rest, controls access via IAM, and logs every read.

2. **SSM Parameter Store standard parameters are free.** Up to 10,000 parameters, no charge. There is no cost excuse for storing secrets in plaintext.

3. **The startup wrapper pattern is reusable.** The same `fetch-from-SSM-then-exec` pattern works for any application in any language. The application does not need to know about SSM.

4. **IAM role permissions can take 30 seconds to propagate.** Do not panic when the first call after a policy change fails. Wait, then retry.

5. **Clean up secrets when services are decommissioned.** Dead credentials in your parameter store are a liability. When you cut an API integration, delete its key from SSM in the same session.

6. **Watch for pagination.** `get-parameters-by-path` returns 10 results by default. If you have more than 10 parameters, you need `--recursive` or explicit pagination handling. A silent partial load is worse than a crash -- your app runs but at reduced capability.

---

**Next module:** [07 - Security Hardening](../07-security-hardening/) -- least-privilege IAM, SSH hardening, and fail2ban.
