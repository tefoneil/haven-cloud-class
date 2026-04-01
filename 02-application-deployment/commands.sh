#!/bin/bash
# =============================================================================
# Module 02: Application Deployment — Commands
# Maps to: AWS-2 (VID-135)
# =============================================================================
# These commands deploy the Haven application to a fresh EC2 Ubuntu instance.
# Run Steps 1-5 and 8 ON THE EC2 INSTANCE (via SSH).
# Run Steps 6-7 FROM YOUR LOCAL MACHINE.
# =============================================================================

# ==========================
# ON THE EC2 INSTANCE (SSH)
# ==========================

# -----------------------------------------------------------
# STEP 1: Install Python 3.12 and System Dependencies
# -----------------------------------------------------------

sudo apt update
sudo apt install -y python3.12 python3.12-venv python3.12-dev

# Verify Python installation
python3.12 --version
# Expected: Python 3.12.3

# -----------------------------------------------------------
# STEP 2: Install Poetry
# -----------------------------------------------------------

# Official installer — do not use pip install poetry (it pollutes global packages)
curl -sSL https://install.python-poetry.org | python3.12 -

# Add Poetry to PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Verify
poetry --version
# Expected: Poetry (version 2.3.2)

# -----------------------------------------------------------
# STEP 3: Set Up Deploy Key for GitHub
# -----------------------------------------------------------

# Generate an ed25519 SSH key (no passphrase for automated deploys)
ssh-keygen -t ed25519 -C "haven-ec2" -f ~/.ssh/haven-ec2 -N ""

# Display the public key — copy this to GitHub
cat ~/.ssh/haven-ec2.pub

# >>> Go to GitHub: Repository > Settings > Deploy keys > Add deploy key
# >>> Title: "haven-ec2"
# >>> Paste the public key
# >>> Do NOT check "Allow write access"

# Configure SSH to use the deploy key for GitHub
cat >> ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/haven-ec2
  IdentitiesOnly yes
EOF

# Test GitHub authentication
ssh -T git@github.com
# Expected: Hi <repo>! You've successfully authenticated...

# -----------------------------------------------------------
# STEP 4: Clone the Repository
# -----------------------------------------------------------

cd ~
git clone git@github.com:ProjectHaven/haven.git
cd haven

# Verify the clone
ls -la
git log --oneline -5

# -----------------------------------------------------------
# STEP 5: Install Python Dependencies
# -----------------------------------------------------------

cd ~/haven
poetry install

# This takes 3-4 minutes on a fresh t3.small.
# The virtual environment is created automatically.

# Find the virtual environment path (you will need this for systemd in Module 03)
poetry env info --path
# Expected: /home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12

# Verify the venv works
poetry run python --version
# Expected: Python 3.12.3

# ==========================
# FROM YOUR LOCAL MACHINE
# ==========================

# -----------------------------------------------------------
# STEP 6: Transfer Secrets via SCP
# -----------------------------------------------------------
# These files contain API keys and runtime config. NEVER commit them to git.

# Transfer .env (30+ API keys, bot tokens, chat IDs)
scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/.env \
  ubuntu@23.22.54.235:/home/ubuntu/haven/.env

# Transfer settings.yaml (runtime thresholds, lane configs)
scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/config/settings.yaml \
  ubuntu@23.22.54.235:/home/ubuntu/haven/config/settings.yaml

# -----------------------------------------------------------
# STEP 7: Transfer the Database
# -----------------------------------------------------------
# 574MB SQLite database. Takes 3-5 minutes depending on upload speed.
#
# IMPORTANT: Do NOT transfer .db-wal or .db-shm files.
# They are ephemeral and will be recreated on daemon start.
# Transferring stale WAL/SHM from a running local daemon can cause corruption.

scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/data/haven.db \
  ubuntu@23.22.54.235:/home/ubuntu/haven/data/haven.db

# ==========================
# BACK ON THE EC2 INSTANCE
# ==========================

# -----------------------------------------------------------
# STEP 8: Verify the Deployment
# -----------------------------------------------------------

# Check the database transferred correctly
ls -lh ~/haven/data/haven.db
# Expected: 574M

# Run SQLite integrity check — THIS IS NON-NEGOTIABLE
cd ~/haven
poetry run python -c "
import sqlite3
conn = sqlite3.connect('data/haven.db')
result = conn.execute('PRAGMA integrity_check').fetchone()
print(f'Integrity: {result[0]}')
tables = conn.execute(\"SELECT COUNT(*) FROM sqlite_master WHERE type='table'\").fetchone()
print(f'Tables: {tables[0]}')
trades = conn.execute('SELECT COUNT(*) FROM paper_trades').fetchone()
print(f'Paper trades: {trades[0]}')
conn.close()
"
# Expected:
#   Integrity: ok
#   Tables: 87
#   Paper trades: 429

# If integrity check fails, do NOT proceed. Re-transfer the database.

# -----------------------------------------------------------
# STEP 9: Manual Test Run
# -----------------------------------------------------------
# Start the daemon manually to verify everything works.
# PYTHONUNBUFFERED=1 is required or Rich console output gets buffered.

cd ~/haven
PYTHONUNBUFFERED=1 poetry run python -m src.automation.haven_daemon

# Watch for:
#   - "Pre-flight integrity check: PASS"
#   - "Registering 34 daemon loops"
#   - All 34 loops show "STARTED"
#   - "Telegram connected"
#   - "All lanes active: A, M, S, EQ"
#   - Heartbeat message arrives in Telegram

# Stop with Ctrl+C once verified.
# Module 03 (systemd) will handle proper process management.

# -----------------------------------------------------------
# UTILITY: Re-deploy After Code Changes
# -----------------------------------------------------------
# After pushing changes to GitHub from your local machine:

cd ~/haven
git pull
poetry install  # only needed if dependencies changed
# Then restart the daemon (Module 03: sudo systemctl restart haven-daemon)

# -----------------------------------------------------------
# UTILITY: Update .env After Adding New API Keys
# -----------------------------------------------------------
# From local machine:

scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/.env \
  ubuntu@23.22.54.235:/home/ubuntu/haven/.env

# Then restart the daemon to pick up new env vars
