# Haven Cloud Class — SAA-C03 Cert Prep Expansion Design

**Date:** 2026-04-02
**Status:** Approved
**Goal:** Expand haven-cloud-class from 9-module portfolio piece to 17-module AWS Solutions Architect Associate (SAA-C03) cert prep course, using Haven as the lens for all services.

---

## Core Principle

**Every module uses Haven as the lens.** Even services Haven didn't deploy are taught through "what if Haven needed this?" scenarios. The reader already knows the application — the service becomes concrete because they can picture exactly where it fits.

## SAA-C03 Exam Domains

| Domain | Weight | Coverage |
|--------|--------|----------|
| Design Secure Architectures | 30% | Modules 07, 15, + Exam Lens sections |
| Design Resilient Architectures | 26% | Modules 04, 09, 11, 13 |
| Design High-Performing Architectures | 24% | Modules 09, 10, 12, 14 |
| Design Cost-Optimized Architectures | 20% | All modules (cost model), Module 16 |

## Module Template (Updated)

Each module follows:
1. **The Problem** — Haven-specific pain point
2. **The Concept** — What the service is, how it works
3. **The Build** — Step-by-step AWS CLI in lab VPC (build + verify + screenshot)
4. **The Teardown** — Explicit destroy commands + cost verification
5. **The Gotcha** — What went wrong
6. **The Result** — Screenshots, proof it works
7. **Key Takeaways** — 3-5 bullets
8. **Exam Lens** — SAA domain mapping, scenario questions, "know the difference" comparisons, cost traps

## Course Structure

### Part 1: The Real Deployment (Modules 00-08) — DONE
*"What we actually built"*

| Module | Title | Status |
|--------|-------|--------|
| 00 | Why Cloud | Written + video |
| 01 | VPC & Compute | Written + video |
| 02 | Application Deployment | Written + video |
| 03 | Process Management | Written + video |
| 04 | Storage & Backups | Written + media pending |
| 05 | Monitoring & Alerting | Written + video |
| 06 | Secrets Management | Written + media pending |
| 07 | Security Hardening | Written + media pending |
| 08 | Operational Dashboards | Written + media pending |

### Part 2: The What-If Expansion (Modules 09-14) — NEW
*"How Haven would use these services"*

| Module | Title | Haven Scenario | Services | Est. Cost |
|--------|-------|---------------|----------|-----------|
| 09 | Databases | "Haven outgrows SQLite" | RDS PostgreSQL, Aurora (explain), DynamoDB | $0.01 / free tier |
| 10 | Serverless Compute | "Briefings go serverless + TradingView webhook" | Lambda, API Gateway | Free tier |
| 11 | Load Balancing & Scaling | "Haven dashboard needs to scale" | ALB, ASG, Launch Templates | ~$0.50 |
| 12 | DNS & Content Delivery | "Give Haven a domain + CDN" | Route 53 (explain), CloudFront | Free tier |
| 13 | Messaging & Decoupling | "Haven goes event-driven" | SQS, SNS (deep), EventBridge | Free tier |
| 14 | Containers | "Dockerize Haven" | Docker, ECR, ECS, Fargate | ~$0.25 |

### Part 3: Exam Readiness (Modules 15-16) — NEW
*"Think like an architect"*

| Module | Title | Content |
|--------|-------|---------|
| 15 | Advanced Security | KMS vs CloudHSM, WAF, Shield, GuardDuty. Conceptual + reference Module 07. |
| 16 | Exam Mastery | Well-Architected Framework (5 pillars) applied to Haven. 20 scenario-based practice questions. Domain review. "Know the difference" cheat sheets. |

### Capstone (Updated)
- 40-question comprehensive quiz (up from 20)
- Domain-organized study guide covering all 17 modules
- Well-Architected review of Haven's full architecture
- Flashcard deck spanning all services

## Infrastructure Isolation

```
Production VPC (10.0.0.0/16) — NEVER TOUCHED
  └── EC2 haven daemon (running 24/7, untouched)

Lab VPC (10.1.0.0/16) — build/teardown zone
  └── Module 09: RDS instance → build, test, screenshot, DESTROY
  └── Module 10: Lambda + API GW → build, test, screenshot, DESTROY
  └── Module 11: ALB + ASG → build, test, screenshot, DESTROY
  └── ... each module builds + tears down in isolation
```

- Haven production is completely isolated
- Lab VPC created once, reused across modules
- All lab resources destroyed after each module
- No NAT Gateway (cost trap)
- No unattached Elastic IPs

## Cost Model

| Item | Cost |
|------|------|
| All module labs combined | < $2 total |
| Haven EC2 (existing, running) | ~$20/mo (already paying) |
| Google AI Plus (NotebookLM) | $3.99/mo |
| Domain for Route 53 (optional) | $12/yr or skip |
| **Total additional cost** | **< $5** |

## Execution Plan

```
Session D2: Write modules 09-14 content (Part 2)
            Build + teardown labs during writing
            Capture screenshots + gotchas

Session D3: Write modules 15-16 content (Part 3)
            Update capstone (40Q quiz + expanded study guide)
            Update main README with full 17-module listing

Session E2: Generate NotebookLM media for modules 09-16
            ~4 videos/day limit → 2 days
```

## Locked Decisions

1. **Haven-centric for ALL modules** — even hypothetical services taught through Haven scenarios
2. **Build and teardown** — real AWS CLI commands, real screenshots, destroy after
3. **Lab VPC isolation** — production Haven is never touched
4. **Exam Lens in every module** — SAA domain mapping + scenario questions
5. **Cost < $5 total** for all new module labs
6. **8 new modules** (09-16) bringing total to 17 + capstone
7. **No domain purchase required** — Route 53 explained conceptually, CloudFront uses CF URL
8. **Teardown checklist** at end of every build module + cost verification command
