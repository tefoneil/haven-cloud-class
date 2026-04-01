# Module 00: Why Cloud?

> Your laptop is not a server. Eventually, it will teach you this the hard way.

---

## The Problem

Haven is a 34-loop async Python daemon. It ingests live crypto market data from 47 sources -- Telegram channels, on-chain wallet tracking, DexScreener, CoinGecko, Helius RPC, CryptoPanic, LunarCrush, and more. It runs 24/7, tracking ~40,000 wallet signals, generating trading intelligence across four asset lanes (Lane A for altcoins, Lane M for mid/major caps, Lane S for new launches, Lane EQ for equities).

For six months, it ran on a MacBook Pro.

That was a mistake.

### What Kept Going Wrong

**Laptop sleep kills async daemons.** Close the lid, walk away, let the screen timeout -- any of these would suspend the process. When the daemon woke up, its 34 async loops were in various states of confusion. Some recovered. Some didn't. The ones that didn't would silently stop processing data, meaning signals were missed and trades went unmonitored.

**SQLite does not forgive unclean shutdowns.** Haven uses SQLite in WAL (Write-Ahead Logging) mode with 70+ tables. WAL mode is fast and allows concurrent reads during writes. But it has a critical requirement: the process must shut down cleanly. If the daemon gets killed mid-write -- which is exactly what happens when macOS suspends a process during sleep -- the WAL file and the main database can fall out of sync.

This is what database corruption looks like in practice:

```
sqlite3.DatabaseError: malformed database schema (sqlite_autoindex_social_creators_1)
```

That error started appearing on every query. Not just queries to `social_creators` -- on ALL queries. An orphaned index from a dropped table was poisoning the entire schema. The daemon was dead.

### The Corruption Timeline

**Corruption Event 1 (February 19):** Orphan SQLite autoindex from a migration that dropped a table but left its auto-generated index behind. The `sqlite_autoindex_social_creators_1` error blocked all database operations. Recovery required `PRAGMA writable_schema=ON` surgery -- deleting the orphan directly from `sqlite_master`. This fixed the immediate problem but exposed deeper corruption: `signal_outcomes` had an invalid root page. We ended up restoring from a backup and replaying migrations.

**Corruption Event 2 (February 22):** WAL corruption from a `kill -9` during a stuck shutdown. The daemon wasn't responding to SIGTERM (it had a shutdown handler, but one of the loops was hung), so we sent SIGKILL. The WAL file was mid-checkpoint. Recovery: restore from backup, lose 18 hours of data.

**Corruption Event 3 (March 3):** The final straw. Laptop went to sleep during an overnight scan cycle. Daemon process was suspended by macOS, then the OOM killer (memory pressure from Chrome + Xcode) terminated it. Database was left with a corrupted WAL. We restored from the March 3 backup and lost 19 paper trades.

Nineteen paper trades. Each one representing days of data collection, signal processing, entry timing, and exit monitoring. Gone.

### The Math That Ended the Debate

Here is what the MacBook deployment was costing:

| Cost | Amount |
|------|--------|
| Data loss from corruption event 1 | 18 hours of signals |
| Data loss from corruption event 2 | 18 hours of signals |
| Data loss from corruption event 3 | 19 paper trades + 3 days of signals |
| Missed trading signals during downtime | Unquantifiable but nonzero |
| Time spent on DB recovery/surgery | ~8 hours across 3 events |
| Stress of wondering if the daemon crashed overnight | Significant |

Here is what an EC2 instance costs:

| Resource | Monthly Cost |
|----------|-------------|
| EC2 t3.small (2 vCPU, 2GB RAM) | ~$15 |
| 30GB gp3 EBS volume | ~$2.40 |
| Elastic IP (while attached) | $3.65 |
| S3 backups (< 1GB) | ~$0.02 |
| **Total** | **~$21/month** |

Twenty-one dollars a month. Less than a Netflix subscription. That is the price of a server that does not sleep, does not run Chrome, does not get its processes killed by macOS memory pressure, and does not corrupt your database because someone closed a laptop lid.

---

## The Concept

### Why Development Machines Are Not Production Servers

A development machine and a production server have fundamentally different jobs:

| Property | Development Machine | Production Server |
|----------|-------------------|------------------|
| Primary purpose | Writing and testing code | Running code 24/7 |
| Sleep/suspend | Normal and expected | Never |
| Reboots | Frequent (updates, restarts) | Rare and controlled |
| Resource contention | Browser, IDE, Slack, Spotify | Your app and nothing else |
| Network | Wi-Fi, may disconnect | Wired datacenter, always connected |
| Power | Battery, may die | Redundant power supplies |
| Process priority | User apps come first | Your daemon IS the priority |
| Backup automation | Manual, maybe | Automated, verified |
| Failure alerting | You notice... eventually | Alarm fires in 60 seconds |

The core insight is this: **a laptop is optimized for the person sitting in front of it.** A server is optimized for the process running on it. These are opposite goals. macOS will happily kill your daemon to free memory for Safari. That is the correct behavior for a laptop. It is catastrophic behavior for a production system.

### What "Production-Ready" Actually Means

Before the migration, Haven had exactly one reliability feature: it ran. After the migration, it would need to satisfy a stricter definition:

1. **Survives reboots.** The daemon starts automatically when the server boots. No human intervention required.

2. **Auto-recovers from crashes.** If the process dies (OOM, unhandled exception, segfault), it restarts within seconds. Automatically.

3. **Backs up data.** The 574MB SQLite database gets backed up to durable storage every 6 hours. WAL-safe backups using SQLite's `.backup` API, not file copies. Versioned. 90-day retention.

4. **Alerts on failure.** If the daemon stops sending heartbeats for more than 2 minutes, an alarm fires and a notification reaches a human. Not "you might notice tomorrow" -- within minutes.

5. **Manages secrets properly.** API keys and tokens are not in a `.env` file on disk. They are in an encrypted secret store, pulled at startup, never written to the filesystem.

6. **Enforces least privilege.** The IAM user that manages the infrastructure cannot delete the VPC. The EC2 instance can write to its backup bucket and nothing else. Every permission is scoped to exactly what is needed.

This is the gap between "it works on my machine" and "it runs in production." Crossing that gap is what this course is about.

---

## The Gotcha

The temptation is to keep putting it off. "The MacBook works fine most of the time." "I'll migrate when I have a free weekend." "The backups will catch most failures."

We told ourselves all of these things. For six months.

The final straw was not the third corruption event itself -- it was looking at the recovery and realizing we had lost 19 paper trades that were part of our Gate 2 evaluation. Haven uses paper trading gates to validate strategy performance before risking real capital. Each lane needs 30-50 closed paper trades with statistical significance (EV > 0, p < 0.10) before it can go live. Losing 19 trades did not just lose data -- it set the timeline back by weeks.

The $20/month for EC2 would have prevented all three corruption events. Every single one. A server that does not sleep cannot corrupt a database during sleep. A server with automated backups does not lose 19 trades. A server with health monitoring does not silently crash at 3 AM and get discovered at 9 AM.

The cost of NOT migrating had been accumulating for months. We just were not counting it.

---

## The Result

The decision was made on March 13, 2026. The migration was executed in two sessions:

- **Session A (March 14):** VPC, EC2 instance, application deployment. Daemon started on EC2 for the first time. All 34 loops initialized, Telegram connected, all four lanes active.
- **Session B (March 15):** systemd, Elastic IP, S3 backups, CloudWatch monitoring, SSM secrets, IAM hardening. Six AWS stories completed in one session.

The target architecture:

```
                    +------------------+
                    |   AWS Cloud      |
                    |                  |
                    |  +------------+  |          +----------+
                    |  |  EC2       |  |          | S3       |
Internet --------→ |  |  t3.small  |  | ------→  | Backups  |
  (SSH only)       |  |  Haven     |  |  (6h)    | (90d)    |
                    |  |  Daemon    |  |          +----------+
                    |  +-----+------+ |
                    |        |        |          +------------+
                    |        |        | ------→  | CloudWatch |
                    |        |        |  (1m)    | Alarms     |
                    |  +-----+------+ |          +------+-----+
                    |  | SSM Params  | |                 |
                    |  | (secrets)   | |          +------+-----+
                    |  +-------------+ |          | SNS/Email  |
                    +------------------+          +------------+
```

**Total migration time:** ~4 hours across two sessions.
**Total monthly cost:** ~$21.
**Database corruptions since migration:** Zero.

---

## Key Takeaways

- **The cost of downtime is always higher than the cost of cloud.** Three corruption events, ~40 hours of lost data, ~8 hours of recovery work, and 19 lost paper trades. That cost dwarfs $21/month.

- **$20/month is cheaper than one lost database.** This is not a hard economic calculation. If your application has data you cannot afford to lose, it belongs on infrastructure designed to protect it.

- **Production workloads need production infrastructure.** A laptop that sleeps, runs other applications, connects over Wi-Fi, and gets carried around in a backpack is not production infrastructure. A server in a datacenter with redundant power, no sleep mode, and automated backups is.

- **"I'll migrate later" is a form of technical debt with compounding interest.** Every day the daemon ran on a laptop was another day of risk. The migration took 4 hours. The procrastination lasted 6 months.

- **SQLite is excellent software with one hard requirement.** It needs clean shutdowns. If you cannot guarantee clean shutdowns -- and you cannot on a laptop -- you need a deployment that can.

---

Next: [Module 01 - VPC & Compute](../01-vpc-and-compute/) -- Building the network and launching the server.
