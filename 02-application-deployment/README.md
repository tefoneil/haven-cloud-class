# Module 02: Application Deployment

> A server without your code is just an expensive heater. Time to fix that.

**Maps to:** AWS-2 (VID-135)
**AWS Services:** EC2, SSH, SCP
**Time to complete:** ~45 minutes (mostly waiting for SCP to transfer 574MB)

---

## The Problem

Haven runs on a MacBook with Homebrew Python 3.12, Poetry for dependency management, and a `.env` file with 30+ API keys (Telegram, CoinGecko, Helius, CryptoPanic, LunarCrush, Jupiter, DexScreener, and more). The SQLite database is 574MB with 70+ tables and 87 active tables including WAL and SHM files.

The EC2 instance from Module 01 is a bare Ubuntu 24.04 server. It has `python3.12` in the apt repos but no Poetry, no project code, no secrets, no database. We need to reproduce the entire development environment on a machine we can only access through a terminal.

There is no GUI. There is no Finder to drag-and-drop files. There is no Homebrew. Every tool is installed via `apt` (Ubuntu's package manager) or `pip`. Every file is transferred via `scp` (secure copy over SSH) or pulled via `git`.

The challenge is not complexity -- it is completeness. Miss one dependency, one environment variable, one file, and the daemon crashes on startup with an import error or a missing API key. Haven imports from 47+ modules and talks to 12 external APIs. Everything must be in place before the first `python` command.

---

## The Concept

### Server Deployment Is Environment Reproduction

When you run code locally, you have accumulated months of implicit state: installed packages, environment variables in your shell profile, config files, database files, Python versions, PATH entries. You do not think about these things because they were set up incrementally over time.

Server deployment forces you to make all of that implicit state explicit. What exact Python version? What packages, at what versions? What environment variables? What files need to exist on disk before the application starts?

### The Tools

**SSH (Secure Shell):** A protocol for running commands on a remote machine over an encrypted connection. You already used it in Module 01 to verify the instance. Now it is your only interface for everything -- installing packages, editing files, running the daemon.

**SCP (Secure Copy Protocol):** Transfers files over SSH. Same authentication (key-based), same encryption. Used for files that should never touch a git repository -- the `.env` file (secrets) and the database (574MB binary).

**Deploy Keys:** A read-only SSH key that grants access to a single GitHub repository. Safer than a personal access token (which grants access to ALL your repos). The EC2 instance gets a deploy key that can `git pull` from the Haven repo and nothing else.

**Poetry:** Python's dependency manager. Reads `pyproject.toml`, resolves dependency versions, creates a virtual environment, installs everything. The `poetry.lock` file ensures the EC2 instance gets exactly the same package versions as the MacBook.

### What Goes Where

| What | Transfer Method | Why |
|------|----------------|-----|
| Application code | `git clone` via deploy key | Version controlled, pull updates easily |
| Python dependencies | `poetry install` on server | Lock file guarantees version parity |
| `.env` file (API keys) | `scp` directly | NEVER commit secrets to git |
| `config/settings.yaml` | `scp` directly | Contains runtime thresholds, may differ per environment |
| `haven.db` (574MB) | `scp` directly | Binary file, not in git, contains all historical data |

---

## The Build

### Step 1: Install Python 3.12 and System Dependencies

SSH into the instance and install the prerequisites:

```bash
ssh -i ~/.ssh/haven-key.pem ubuntu@23.22.54.235
```

```bash
# Update package lists
sudo apt update

# Install Python 3.12 and development headers
# python3.12-venv is required for Poetry to create virtual environments
sudo apt install -y python3.12 python3.12-venv python3.12-dev

# Verify
python3.12 --version
# Python 3.12.3
```

Ubuntu 24.04 ships with Python 3.12 in its default repos. No PPA needed. On older Ubuntu versions (22.04), you would need `add-apt-repository ppa:deadsnakes/ppa` first.

### Step 2: Install Poetry

```bash
# Install Poetry via the official installer
curl -sSL https://install.python-poetry.org | python3.12 -

# Add Poetry to PATH (the installer tells you this)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Verify
poetry --version
# Poetry (version 2.3.2)
```

Poetry installs to `~/.local/bin` by default. If you skip the PATH addition, every Poetry command fails with "command not found" and you will waste 10 minutes before realizing the binary exists but is not on PATH.

### Step 3: Set Up Deploy Key for GitHub

Generate an SSH key on the EC2 instance for GitHub access:

```bash
# Generate an ed25519 key (no passphrase for automated deploys)
ssh-keygen -t ed25519 -C "haven-ec2" -f ~/.ssh/haven-ec2 -N ""

# Print the public key
cat ~/.ssh/haven-ec2.pub
```

Copy the public key output. In GitHub:
1. Go to the Haven repository Settings
2. Deploy keys > Add deploy key
3. Title: "haven-ec2"
4. Paste the public key
5. Do NOT check "Allow write access" -- read-only is safer

Configure SSH to use this key for GitHub:

```bash
cat >> ~/.ssh/config << 'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/haven-ec2
  IdentitiesOnly yes
EOF
```

Test the connection:

```bash
ssh -T git@github.com
# Hi ProjectHaven/haven! You've successfully authenticated...
```

### Step 4: Clone the Repository

```bash
cd ~
git clone git@github.com:ProjectHaven/haven.git
cd haven
```

The repo contains all application code, migration files, config templates, and the `pyproject.toml` / `poetry.lock` that define dependencies. It does NOT contain `.env`, `settings.yaml`, or the database -- those are transferred separately.

### Step 5: Install Dependencies

```bash
cd ~/haven
poetry install
```

This reads `poetry.lock` and installs every package at the exact pinned version. On a fresh t3.small, this takes about 3-4 minutes. The virtual environment is created at:

```
/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12
```

Note: this path is different from the Mac path (`/Users/brandon/Library/Caches/pypoetry/virtualenvs/project-haven-XldOE3uu-py3.12`). The hash in the directory name is generated from the project path, so it differs per machine. This matters when you write systemd service files or scripts that reference the Python binary directly.

To find the exact path:

```bash
poetry env info --path
# /home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12
```

### Step 6: Transfer Secrets via SCP

From your **local machine** (not the EC2 instance):

```bash
# Transfer .env file
scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/.env \
  ubuntu@23.22.54.235:/home/ubuntu/haven/.env

# Transfer settings.yaml
scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/config/settings.yaml \
  ubuntu@23.22.54.235:/home/ubuntu/haven/config/settings.yaml
```

The `.env` file contains 30+ API keys, bot tokens, and chat IDs. It is the single most sensitive file in the project. It is in `.gitignore` and must NEVER be committed. SCP transfers it over the same encrypted SSH channel used for shell access.

### Step 7: Transfer the Database

This is the big one. The SQLite database is 574MB -- it contains all historical messages (233K+), wallet signals (31K+), paper trades (429), and migration state.

```bash
# From your local machine
scp -i ~/.ssh/haven-key.pem \
  /Users/brandon/Desktop/ProjectHavenv2/data/haven.db \
  ubuntu@23.22.54.235:/home/ubuntu/haven/data/haven.db
```

This takes 3-5 minutes depending on upload speed. Do NOT transfer the WAL or SHM files -- they are ephemeral and will be recreated when the daemon starts. Transferring stale WAL/SHM files from a running local daemon can cause corruption on the remote.

Verify the transfer on the EC2 instance:

```bash
# Check file size
ls -lh ~/haven/data/haven.db
# -rw-r--r-- 1 ubuntu ubuntu 574M Mar 14 19:22 haven.db

# Run integrity check
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
# Integrity: ok
# Tables: 87
# Paper trades: 429
```

If the integrity check does not return "ok", do NOT start the daemon. Re-transfer the file. If it still fails, the source database may be corrupted -- check the local copy first.

### Step 8: First Run -- Manual Verification

Start the daemon manually to verify everything works:

```bash
cd ~/haven
PYTHONUNBUFFERED=1 poetry run python -m src.automation.haven_daemon
```

Watch the startup output. You are looking for:

```
[HavenDaemon] Pre-flight integrity check: PASS
[HavenDaemon] Registering 34 daemon loops...
[HavenDaemon] Loop #1: message_ingestion — STARTED
[HavenDaemon] Loop #2: signal_detection — STARTED
...
[HavenDaemon] Loop #34: lane_eq_scanner — STARTED
[HavenDaemon] Telegram connected
[HavenDaemon] All lanes active: A, M, S, EQ
```

All 34 loops must register and start. The Telegram connection must succeed (this validates the bot token in `.env`). The pre-flight integrity check must pass (this runs `PRAGMA integrity_check` on startup).

Once you see the heartbeat message arrive in Telegram, the deployment is verified. Stop the daemon with `Ctrl+C` -- we will set up proper process management in Module 03.

---

## The Gotcha

Three things that were not obvious and cost time:

### 1. Poetry Virtual Env Path Differs Per Machine

The Mac path:
```
/Users/brandon/Library/Caches/pypoetry/virtualenvs/project-haven-XldOE3uu-py3.12
```

The EC2 path:
```
/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12
```

The hash suffix (`XldOE3uu` vs `Q6auRe72`) is derived from the project directory path. Since the project lives at `/Users/brandon/Desktop/ProjectHavenv2` locally and `/home/ubuntu/haven` on EC2, the hashes differ. Any script, service file, or configuration that hardcodes the full Python path must use the correct one for the target machine.

Always use `poetry env info --path` to find the actual path rather than guessing.

### 2. PYTHONUNBUFFERED=1 Is Required

Haven uses Rich for console logging (colorized, formatted output). Rich writes to stdout, and Python buffers stdout when it detects the output is not a terminal (which is the case when running under systemd or redirecting to a file). Without `PYTHONUNBUFFERED=1`:

- `journalctl` shows nothing for minutes at a time, then dumps a huge block of output
- Log files appear empty even though the daemon is running
- Crash debugging becomes impossible because the last lines before the crash were still in the buffer

Set `PYTHONUNBUFFERED=1` in the environment for every daemon invocation. In Module 03, we add it to the systemd service file.

### 3. Never Commit .env to Git

This sounds obvious. It is stated in every tutorial. People still do it. Here is why it is especially dangerous for Haven:

The `.env` file contains Telegram bot tokens that can send messages to real channels, API keys with rate limits and billing, and (once auto-execution is enabled) keys that can execute trades. A leaked `.env` in git history is not fixed by deleting the file -- git remembers everything. You would need to rotate every single key.

SCP the `.env` directly. If you need to update it, SCP again or edit in place via SSH. The file never touches a git repository, a commit message, a PR diff, or a GitHub notification email.

---

## The Result

After all eight steps, the Haven daemon runs on EC2:

```
[2026-03-14 19:45:32] HavenDaemon starting on haven-daemon (Linux)
[2026-03-14 19:45:33] Pre-flight integrity check: PASS (87 tables, 429 paper trades)
[2026-03-14 19:45:33] Registering 34 daemon loops...
[2026-03-14 19:45:34] All loops registered and started
[2026-03-14 19:45:34] Telegram connected — bot @HavenAlertBot
[2026-03-14 19:45:34] Lanes active: A (34/50), M (115 closed), S (3/30), EQ (11/50)
[2026-03-14 19:45:35] Heartbeat sent to Telegram
```

The first heartbeat arrived on Brandon's phone at 7:45 PM. The daemon was running in Virginia, 400 miles away from the MacBook that had been hosting it. It was processing live Telegram messages, tracking wallet signals, monitoring paper trade exits, and scanning for new opportunities -- exactly as it had been doing locally, but now on a machine that would not go to sleep.

At this point, the daemon runs but has no safety net. If the SSH session disconnects, the process dies. If the server reboots, the daemon does not come back. If it crashes at 3 AM, nobody knows until morning.

That is what Module 03 (systemd) fixes.

---

## Key Takeaways

- **Deploy keys (read-only) are safer than personal access tokens.** A deploy key grants access to one repository. A personal access token grants access to every repository on your account. If the EC2 instance is compromised, the blast radius of a deploy key is one repo. The blast radius of a PAT is your entire GitHub account.

- **SCP for secrets, git for code.** Code is version-controlled and public (or at least shared). Secrets are neither. They travel via SCP (encrypted, point-to-point, no history) and live only on the machines that need them. Two different categories of data, two different transfer methods.

- **Always verify the application runs manually before automating.** It is tempting to jump straight to systemd after installing dependencies. Do not. Run the daemon by hand, watch the startup output, confirm all loops register, confirm Telegram connects. If there is a missing dependency or a bad config value, you want to see the error in your terminal, not buried in `journalctl` output.

- **The database integrity check is non-negotiable after transfer.** SCP can fail silently (partial transfer on network interruption). SQLite can be corrupted by transferring WAL/SHM files from a running instance. Always run `PRAGMA integrity_check` after copying the database. If it does not say "ok", do not start the daemon.

- **PYTHONUNBUFFERED=1 saves hours of debugging.** Without it, Python buffers stdout and your logs appear empty or delayed. Every Python process that writes to stdout in a non-interactive context (systemd, cron, nohup) needs this flag.

---

Next: [Module 03 - Process Management](../03-process-management/) -- Making the daemon survive reboots and crashes with systemd.
