#!/bin/bash
# =============================================================================
# Haven Daemon Startup Wrapper
# =============================================================================
# This script fetches secrets from AWS SSM Parameter Store and injects them as
# environment variables before starting the daemon. It replaces the .env file.
#
# How it works:
#   1. Calls SSM to fetch all /haven/* parameters (decrypted)
#   2. Exports each parameter as an environment variable
#   3. exec's the daemon process (replaces this shell — systemd sees one PID)
#
# Usage:
#   Called by systemd via ExecStart in haven-daemon.service
#   Can also be run manually for testing:
#     ./start-daemon.sh
#
# Why exec instead of just running python?
#   exec replaces the shell process with the Python process. This means:
#   - systemd sends SIGTERM directly to the daemon (not to a parent shell)
#   - There is one PID, not two (shell + python)
#   - The daemon's graceful shutdown handler (SIGTERM → close loops) works correctly
#   Without exec, SIGTERM goes to the shell, the shell dies, and the daemon
#   gets SIGHUP (which it may not handle) or becomes an orphan.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REGION="us-east-1"
SSM_PATH="/haven/"

# Poetry virtualenv path on EC2
# Found via: poetry env info --path (run from /home/ubuntu/haven)
VENV_PYTHON="/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12/bin/python"

# Working directory — the daemon expects to run from the repo root
# (SQLite path is relative: data/haven.db)
WORKDIR="/home/ubuntu/haven"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

# Verify the Python interpreter exists
if [ ! -f "$VENV_PYTHON" ]; then
    echo "ERROR: Python interpreter not found at $VENV_PYTHON"
    echo "Run 'poetry install' in $WORKDIR first."
    exit 1
fi

# Verify AWS CLI is available (needed for SSM calls)
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI not found. Install with: sudo apt install awscli"
    exit 1
fi

# Verify we can reach SSM (catches IAM issues early)
# This is a cheap call — just checks if the path exists
if ! aws ssm get-parameters-by-path \
    --path "$SSM_PATH" \
    --region "$REGION" \
    --max-items 1 \
    --query "Parameters[0].Name" \
    --output text > /dev/null 2>&1; then
    echo "ERROR: Cannot read SSM path $SSM_PATH"
    echo "Check IAM role permissions for ssm:GetParametersByPath"
    echo "Note: IAM changes take up to 30 seconds to propagate"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fetch secrets from SSM
# ---------------------------------------------------------------------------

echo "Fetching secrets from SSM path: $SSM_PATH"

# --with-decryption: Decrypt SecureString values (requires kms:Decrypt)
# --recursive:       Follow nested paths AND handle pagination (critical for 30+ params)
# --output json:     Machine-parseable output for the Python helper below
#
# The --query flag extracts just the Name and Value fields. We don't need
# Type, Version, ARN, etc.
PARAMS=$(aws ssm get-parameters-by-path \
    --path "$SSM_PATH" \
    --with-decryption \
    --recursive \
    --region "$REGION" \
    --query "Parameters[*].{Name:Name,Value:Value}" \
    --output json)

# ---------------------------------------------------------------------------
# Export as environment variables
# ---------------------------------------------------------------------------

# Why Python instead of bash for this?
#
# The naive bash approach:
#   for param in $(echo $PARAMS | jq -r ...); do
#       export KEY="$VALUE"
#   done
#
# Breaks on:
#   - Values with spaces
#   - Values with single quotes (some API keys have these)
#   - Values with dollar signs (interpreted as variable references)
#   - Values with backticks (interpreted as command substitution)
#
# The Python approach handles all of these by properly escaping single quotes
# in the shell-safe format: val' → val'\''
# (close quote, escaped literal quote, reopen quote)

eval $(echo "$PARAMS" | python3 -c "
import sys, json

params = json.loads(sys.stdin.read())
count = 0

for p in params:
    # Extract variable name from SSM path
    # /haven/HELIUS_API_KEY → HELIUS_API_KEY
    key = p['Name'].split('/')[-1]

    # Escape single quotes for shell safety
    # This handles the case where an API key contains a literal '
    # Shell form: 'value'\''s' (close-quote, escaped-quote, reopen-quote)
    val = p['Value'].replace(\"'\", \"'\\\\''\")

    # Output a shell export statement
    print(f\"export {key}='{val}'\")
    count += 1

# Print count to stderr (won't be eval'd)
print(f'Loaded {count} parameters from SSM', file=sys.stderr)
")

# ---------------------------------------------------------------------------
# Start the daemon
# ---------------------------------------------------------------------------

echo "Starting Haven daemon..."

# Change to the working directory (daemon expects repo root for relative paths)
cd "$WORKDIR"

# exec replaces this shell process with the Python process
# - PID stays the same (systemd tracks one process)
# - SIGTERM goes directly to Python (graceful shutdown works)
# - Environment variables we exported above are inherited
#
# -u flag: unbuffered stdout/stderr (same as PYTHONUNBUFFERED=1)
#   Without this, print() output may not appear in journalctl until
#   the buffer fills or the process exits. With 34 async loops logging
#   at different rates, buffered output makes debugging impossible.
exec "$VENV_PYTHON" -u -m src.automation.haven_daemon
