# Module 03: Process Management

> Maps to: AWS-3 (VID-136) | AWS Services: systemd

---

## The Problem

Haven's daemon was running on EC2. We SSH'd in, activated the Poetry virtualenv, ran `nohup python -m src.automation.haven_daemon start &`, confirmed the 34 loops were spinning, and disconnected. It felt production-ready.

It was not.

Here is what `nohup` actually gives you:

- Process survives SSH disconnect. That is it.
- Server reboots? Daemon is gone. Nobody starts it.
- Daemon crashes at 3 AM from an unhandled exception in loop #14? It stays dead. No restart. No notification. You wake up, check your phone, see zero Telegram alerts for 8 hours, and realize your entire data pipeline has been offline since the CoinGecko rate limiter threw a `ConnectionResetError`.
- Want to check logs? Hope you remembered to redirect stdout. Hope the log file did not fill the disk. Hope the process did not silently die and leave a stale PID file.

Haven processes live crypto market data across 47 sources. Downtime means missed signals, missed exits on open paper trades, and gaps in the 228K-message dataset that took months to build. "It'll probably stay up" is not a recovery strategy.

We needed a process supervisor — something that starts the daemon on boot, restarts it on crash, captures logs, and integrates with the OS. On Linux, that tool is systemd.

---

## The Concept

### What is systemd?

systemd is Linux's init system and service manager. It is the first process that runs when a Linux server boots (PID 1), and it manages every other service on the system — SSH, networking, cron, and your applications.

When you write a **unit file**, you are telling systemd: "Here is a process I want you to manage. Start it, watch it, and restart it if it dies."

### Key components

| Component | What It Does |
|-----------|-------------|
| **Unit file** | A config file (`.service`) that describes your process — what to run, as which user, in what directory |
| **systemctl** | The CLI tool to start, stop, enable, disable, and inspect services |
| **journald** | systemd's built-in log aggregator — captures stdout/stderr from every managed service |
| **journalctl** | The CLI tool to query journald logs — filter by service, time range, priority |

### Why not nohup, screen, or tmux?

| Approach | Survives SSH Disconnect | Survives Crash | Survives Reboot | Structured Logs | Zero Config After Setup |
|----------|:-:|:-:|:-:|:-:|:-:|
| `nohup ... &` | Yes | No | No | No | N/A |
| `screen` / `tmux` | Yes | No | No | No | N/A |
| **systemd** | Yes | **Yes** | **Yes** | **Yes** | **Yes** |

Screen and tmux are interactive session tools. They keep a terminal alive, but they do not restart crashed processes or survive reboots. They are tools for humans, not for production services.

systemd is a process supervisor. It does not care about terminals. It watches PIDs, catches exit codes, and acts on policies you define.

### The lifecycle

```
                Boot
                  │
          ┌───────▼────────┐
          │  systemd (PID 1) │
          └───────┬────────┘
                  │  reads unit files
                  ▼
          ┌──────────────┐
          │  haven-daemon  │──── running (34 loops)
          └──────┬───────┘
                 │
        crash? ──┤── restart after RestartSec
                 │
        stop?  ──┤── SIGTERM → graceful shutdown
                 │
        reboot?──┤── started again at boot (WantedBy=multi-user)
                 │
        logs?  ──┴── journalctl -u haven-daemon
```

---

## The Build

### Step 1: Write the unit file

The unit file goes in `/etc/systemd/system/`, which is the standard location for admin-created services. The filename becomes the service name.

```bash
sudo nano /etc/systemd/system/haven-daemon.service
```

Here is the full file (also available as `haven-daemon.service` in this module):

```ini
[Unit]
Description=Haven Daemon - Crypto Intelligence Pipeline (34 async loops)
After=network.target
# Wait for networking — daemon needs outbound HTTPS for Telegram, CoinGecko,
# Helius, DexScreener, CryptoPanic, and 40+ other APIs.

[Service]
Type=simple
# "simple" means systemd considers the service started as soon as ExecStart runs.
# Correct for long-running daemons. Use "forking" only if the process forks and
# the parent exits (Haven does not do this).

User=ubuntu
# Run as ubuntu, not root. The daemon never needs root privileges.
# Principle of least privilege — if the process is compromised, the attacker
# gets ubuntu-level access, not root.

WorkingDirectory=/home/ubuntu/haven
# The daemon reads config/settings.yaml and writes to data/haven.db
# using relative paths. WorkingDirectory ensures those resolve correctly.

ExecStart=/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12/bin/python -m src.automation.haven_daemon start
# Points directly at the Python binary inside Poetry's virtualenv.
# We do NOT use "poetry run" because it adds startup overhead and
# can fail if Poetry's shim is not on root's PATH.
#
# The "start" argument is required — haven_daemon.py uses argparse
# with choices=["start", "status", "stop"]. Without it, you get:
#   error: the following arguments are required: command

Restart=always
# Restart the daemon no matter how it exits — clean exit, crash, OOM kill.
# For a 24/7 data pipeline, "always" is correct. Use "on-failure" only if
# you want clean exits (exit code 0) to stay down.

RestartSec=10
# Wait 10 seconds before restarting. Gives time for:
# - Transient network issues to clear
# - Rate-limited APIs to cool down
# - SQLite WAL checkpoints to flush
# Without this, a crash-loop hammers the system with rapid restarts.

TimeoutStopSec=30
# How long to wait after SIGTERM before sending SIGKILL.
# Default is 90 seconds, which is too long.
# Haven's asyncio loops need ~5-15 seconds to drain, but some loops
# (like the Telegram listener) do not handle SIGTERM gracefully.
# 30 seconds gives enough time for clean shutdown without blocking
# restarts for 90 seconds when the daemon hangs.

Environment=PYTHONUNBUFFERED=1
# Critical for Python logging. Without this, Python buffers stdout
# and log lines arrive in journald in unpredictable chunks — or not
# at all if the process crashes before the buffer flushes.
# PYTHONUNBUFFERED=1 forces line-by-line output to journald.

StandardOutput=journal
StandardError=journal
SyslogIdentifier=haven-daemon
# Route all output to journald under the identifier "haven-daemon".
# This replaces manual log file management entirely.
# No more nohup.out. No more >> daemon.log 2>&1. No more log rotation.

[Install]
WantedBy=multi-user.target
# Start this service when the system reaches multi-user mode (normal boot).
# This is what makes "systemctl enable" work — it creates a symlink
# so systemd knows to start haven-daemon at boot.
```

### Step 2: Reload systemd and enable the service

```bash
# Tell systemd to re-read unit files (required after creating or editing one)
sudo systemctl daemon-reload

# Enable = "start this service on boot"
# This creates a symlink in /etc/systemd/system/multi-user.target.wants/
sudo systemctl enable haven-daemon

# Start the service now
sudo systemctl start haven-daemon
```

### Step 3: Verify it is running

```bash
# Check service status
sudo systemctl status haven-daemon
```

Expected output:

```
● haven-daemon.service - Haven Daemon - Crypto Intelligence Pipeline (34 async loops)
     Loaded: loaded (/etc/systemd/system/haven-daemon.service; enabled; preset: enabled)
     Active: active (running) since Sat 2026-03-15 18:42:31 UTC; 5s ago
   Main PID: 12847 (python)
      Tasks: 3 (limit: 2315)
     Memory: 187.4M
        CPU: 4.521s
     CGroup: /system.slice/haven-daemon.service
             └─12847 /home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12/bin/python -m src.automation.haven_daemon start
```

Key things to verify:
- `enabled` — will start on boot
- `active (running)` — currently alive
- Memory ~187MB — reasonable for 34 async loops + SQLite connections

### Step 4: Check logs via journalctl

```bash
# Follow logs in real time (like tail -f)
sudo journalctl -u haven-daemon -f

# View last 100 lines
sudo journalctl -u haven-daemon -n 100

# View logs since last boot
sudo journalctl -u haven-daemon -b

# View logs from a specific time
sudo journalctl -u haven-daemon --since "2026-03-15 18:00"

# View only errors
sudo journalctl -u haven-daemon -p err
```

### Step 5: Test crash recovery

This is the most important test. If you skip this, you do not know if your safety net works.

```bash
# Find the daemon's PID
sudo systemctl status haven-daemon | grep "Main PID"
# Main PID: 12847 (python)

# Kill it with SIGKILL (simulates an unrecoverable crash — OOM, segfault)
sudo kill -9 12847

# Wait 10 seconds (RestartSec=10), then check
sudo systemctl status haven-daemon
```

Expected: the service is `active (running)` again with a new PID. journalctl will show:

```
Mar 15 18:45:02 ip-10-0-1-x systemd[1]: haven-daemon.service: Main process exited, code=killed, status=9/KILL
Mar 15 18:45:12 ip-10-0-1-x systemd[1]: haven-daemon.service: Scheduled restart job, restart counter is at 1.
Mar 15 18:45:12 ip-10-0-1-x systemd[1]: Started haven-daemon.service - Haven Daemon - Crypto Intelligence Pipeline (34 async loops).
```

### Step 6: Test reboot recovery

```bash
# Reboot the server
sudo reboot

# Wait ~60 seconds, SSH back in
ssh -i ~/.ssh/haven-key.pem ubuntu@52.5.244.137

# Check — should be running without manual intervention
sudo systemctl status haven-daemon
```

If this shows `active (running)` with a start time matching the boot time, you are production-ready.

---

## The Gotcha

Two things went wrong on the first attempt.

### Gotcha 1: Missing `start` argument

The first version of the unit file had:

```ini
ExecStart=/home/ubuntu/.cache/.../python -m src.automation.haven_daemon
```

systemd started the process, it immediately printed:

```
error: the following arguments are required: command
```

And exited. systemd dutifully restarted it. Same error. Restart. Same error. After 5 rapid restarts, systemd hit the `StartLimitBurst` and marked the service as **failed**.

The fix was adding `start` to the ExecStart line. Haven's daemon uses `argparse` with `choices=["start", "status", "stop"]` — it expects a subcommand.

**Lesson:** Always test your ExecStart command manually first. SSH in, paste the full command, confirm it runs. Then put it in the unit file.

```bash
# Test the exact command that will go in ExecStart
/home/ubuntu/.cache/pypoetry/virtualenvs/project-haven-Q6auRe72-py3.12/bin/python -m src.automation.haven_daemon start
```

### Gotcha 2: SIGTERM timeout

When stopping the daemon with `systemctl stop`, systemd sends SIGTERM and waits. Haven's asyncio event loop does not have a SIGTERM handler — it does not catch the signal and gracefully cancel tasks. The daemon just keeps running until systemd gives up.

The default `TimeoutStopSec` is 90 seconds. That means every `systemctl restart` took 90 seconds of waiting, followed by a SIGKILL, followed by the restart. For a deploy workflow where you do `git pull && systemctl restart haven-daemon`, waiting 90 seconds is unacceptable.

Setting `TimeoutStopSec=30` fixed the practical problem. The daemon gets 30 seconds to shut down (more than enough for any in-flight DB writes to complete), then systemd force-kills it.

**The proper fix** (deferred) is adding a SIGTERM handler in `haven_daemon.py` that cancels all asyncio tasks and shuts down cleanly. But the systemd timeout is the right safety net regardless — you never want a stop command to hang indefinitely.

---

## The Result

After applying both fixes, the daemon runs with full production resilience:

```bash
# Normal operation
$ sudo systemctl status haven-daemon
● haven-daemon.service - Haven Daemon - Crypto Intelligence Pipeline (34 async loops)
     Active: active (running) since Sat 2026-03-15 18:42:31 UTC; 2h ago

# Crash recovery (kill -9 → back in 10 seconds)
$ sudo kill -9 $(pgrep -f haven_daemon)
$ sleep 12
$ sudo systemctl status haven-daemon
     Active: active (running) since Sat 2026-03-15 20:44:43 UTC; 2s ago

# Reboot recovery (automatic, no SSH required)
$ sudo reboot
# ... SSH back in 60 seconds later ...
$ sudo systemctl status haven-daemon
     Active: active (running) since Sat 2026-03-15 20:46:15 UTC; 45s ago

# Live log inspection
$ sudo journalctl -u haven-daemon -f
Mar 15 20:46:16 ip-10-0-1-x python[13201]: [INFO] Pre-flight integrity check: PASS
Mar 15 20:46:16 ip-10-0-1-x python[13201]: [INFO] All 34 loops registered
Mar 15 20:46:17 ip-10-0-1-x python[13201]: [INFO] Telegram connected — monitoring 47 channels
Mar 15 20:46:17 ip-10-0-1-x python[13201]: [INFO] Lane A: active | Lane M: active | Lane S: active | Lane EQ: active
Mar 15 20:46:17 ip-10-0-1-x python[13201]: [INFO] Exit engine loaded — monitoring 5 open paper trades
```

The daemon now survives everything short of the EC2 instance being terminated. And even that is recoverable — the instance can be relaunched and the daemon starts automatically.

---

## Key Takeaways

- **systemd replaces nohup, screen, and tmux for production services.** Those tools keep processes alive across SSH disconnects. systemd keeps them alive across crashes, reboots, and OOM kills.

- **`Restart=always` is your safety net.** For a 24/7 daemon, you want restarts on every exit — clean or otherwise. Pair it with `RestartSec=10` to avoid crash-looping.

- **Always test crash recovery and reboot recovery.** Run `kill -9` on your process and confirm it comes back. Run `sudo reboot` and confirm it starts on boot. If you skip these tests, you are assuming your config is correct without evidence.

- **`PYTHONUNBUFFERED=1` is critical for Python + journald.** Without it, Python's output buffering means log lines arrive late, in chunks, or not at all if the process crashes. One environment variable fixes this entirely.

- **Test your ExecStart command manually before putting it in a unit file.** Copy the full command, paste it into your SSH session, and confirm the process starts. This catches missing arguments, wrong paths, and permission issues before systemd's restart loop does.

- **`TimeoutStopSec` matters for deploy workflows.** If your daemon does not handle SIGTERM gracefully, the default 90-second timeout makes every restart painfully slow. Set it to something reasonable (15-30 seconds) and plan to add a proper signal handler later.

---

## Common Commands Reference

```bash
# Service management
sudo systemctl start haven-daemon        # Start the service
sudo systemctl stop haven-daemon         # Stop (SIGTERM → wait → SIGKILL)
sudo systemctl restart haven-daemon      # Stop + Start
sudo systemctl status haven-daemon       # Current state + recent logs
sudo systemctl enable haven-daemon       # Start on boot
sudo systemctl disable haven-daemon      # Do not start on boot

# After editing the unit file
sudo systemctl daemon-reload             # Re-read unit files
sudo systemctl restart haven-daemon      # Apply changes

# Log inspection
sudo journalctl -u haven-daemon -f       # Follow live (tail -f equivalent)
sudo journalctl -u haven-daemon -n 200   # Last 200 lines
sudo journalctl -u haven-daemon -b       # Since last boot
sudo journalctl -u haven-daemon -p err   # Errors only
sudo journalctl -u haven-daemon --since "1 hour ago"
```

---

## Files in This Module

| File | Description |
|------|-------------|
| `README.md` | This document |
| `haven-daemon.service` | Annotated systemd unit file — copy to `/etc/systemd/system/` |

---

*Next module: [04 - Storage & Backups](../04-storage-and-backups/) — automated S3 backups for Haven's 574MB SQLite database.*
