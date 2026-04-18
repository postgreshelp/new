# Episode 2: Can AI Replace a DBRE?
### Live AWS Demo — PostgreSQL 17 — 4/4 Tests Pass — 3 Judgment Calls

---

## The Hook: GitLab 2017

In 2017, a GitLab engineer accidentally deleted 300GB of production data during a maintenance window. It wasn't a complex attack. No zero-day exploit. Just a tired engineer, a runbook that assumed the wrong server, and a backup system that had never been validated.

The outage lasted 18 hours. The engineer had the knowledge. He just didn't have the automation, the guardrails, or the second set of eyes.

**The question this experiment asks:** Could AI have built what was missing?

---

## The Experiment

| Human DBRE | AI (Claude Code) |
|---|---|
| 2–3 days | 25 minutes |
| Full stack build | One prompt → deploy → test → destroy |
| Deep judgment | Pattern matching at scale |

**What was tested:**
1. Can AI build a production-grade PostgreSQL stack on AWS from a single prompt?
2. Can AI make real production decisions where context and judgment matter?
3. What does a security scanner find in AI-generated infrastructure?

---

## The Approximate Prompt

> The actual prompt was not saved verbatim, but based on what was generated, it covered approximately:
>
> *"Build a complete AWS infrastructure for a PostgreSQL DBRE tooling stack using Terraform. Include: VPC with public subnets, RDS PostgreSQL 17 on db.t3.micro in us-east-1, SSM Parameter Store for credentials, an IAM-based Lambda function that checks table bloat via pg_stat_user_tables, CloudWatch alarms for CPU and connections with SNS email alerts, a parameter group with production-grade GUCs (log_min_duration_statement, idle_in_transaction_session_timeout, statement_timeout, log_connections, track_io_timing), and a migration safety checker that blocks dangerous SQL patterns. Write Python tests that validate each component end-to-end against real AWS."*

**Time to deployment: ~25 minutes.** AI self-corrected 3 bugs mid-run without being prompted.

---

## What AI Built

### Infrastructure (Terraform — 8 files)

| File | Resources |
|------|-----------|
| `main.tf` | Provider + AWS config |
| `vpc.tf` | VPC, 2 public subnets, IGW, route table, security group |
| `rds.tf` | RDS PostgreSQL 17, subnet group, parameter group (6 GUCs) |
| `lambdas.tf` | IAM role, inline policy, archive, `aws_lambda_function` |
| `ssm.tf` | 5 SSM SecureString parameters (host, port, user, pass, db) |
| `monitoring.tf` | SNS topic, email subscription, 2 CloudWatch alarms |
| `variables.tf` | db_password, aws_region, alert_email |
| `outputs.tf` | Endpoint, port, username, connection string |

### Application Code

**`lambdas/bloat_monitor/lambda_function.py`**
- Pulls all 5 DB credentials from SSM with decryption
- Connects to RDS via psycopg2
- Queries `pg_stat_user_tables` for dead tuple ratio
- Classifies tables: `CRITICAL` (>50%), `WARNING` (>20%), `OK`
- Returns structured JSON result

**`tools/migration_checker.py`**
- Scans SQL files line by line
- 5 regex rules: CREATE INDEX without CONCURRENTLY, ALTER COLUMN TYPE, NOT NULL without NOT VALID, DELETE without WHERE (BLOCK), DROP TABLE/COLUMN
- Exit codes: 0=PASS, 1=WARN, 2=BLOCK

### Parameter Group — 6 GUCs Correctly Configured

| GUC | Value | Purpose |
|-----|-------|---------|
| `shared_preload_libraries` | `pg_stat_statements` | Query performance tracking |
| `log_min_duration_statement` | `1000` ms | Slow query logging |
| `idle_in_transaction_session_timeout` | `300000` ms | Kill idle transactions |
| `statement_timeout` | `60000` ms | Kill runaway queries |
| `log_connections` | `1` | Audit connection events |
| `track_io_timing` | `1` | I/O performance visibility |

---

## Live Test Results: 4/4 Passing

All tests run against **real AWS** — RDS PostgreSQL 17.6, us-east-1, db.t3.micro.

### Test 01 — Connection & Version (`test_connection.py`)
**6/6 PASS**
- RDS endpoint reachable
- PostgreSQL 17.6 confirmed (version string check)
- `pg_stat_statements` extension loaded and queryable
- Connection parameters matched SSM values
- SSL negotiation successful
- Response time under threshold

### Test 02 — Parameter Group (`test_parameter_group.py`)
**6/6 PASS**
- All 6 GUCs present and at expected values
- `idle_in_transaction_session_timeout = 300000`
- `statement_timeout = 60000`
- `log_min_duration_statement = 1000`
- `log_connections = on`
- `track_io_timing = on`
- `pg_stat_statements` in `shared_preload_libraries`

### Test 03 — Bloat Monitor Lambda (`test_bloat_monitor.py`)
**5/5 PASS**
- Lambda function exists in AWS
- Lambda → SSM → RDS flow executes end-to-end
- `pg_stat_user_tables` query returns results
- **50.0% dead tuple ratio detected** on a seeded table
- CRITICAL classification triggered and returned correctly

### Test 04 — Migration Checker (`test_migration_checker.py`)
**6/6 PASS**
- `V001_clean.sql` — no patterns → PASS (exit 0)
- `V002_dangerous.sql` — all 4 dangerous patterns caught:
  - CREATE INDEX without CONCURRENTLY → WARN
  - ALTER COLUMN TYPE → WARN
  - DELETE without WHERE → **BLOCK**
  - DROP TABLE → WARN
- Exit code = 2 (BLOCK) as expected

### Self-Corrections Mid-Run (no human prompt needed)
1. **AZ requirement** — RDS subnet group needs 2 AZs; AI added `public_b` subnet automatically
2. **PG17 GUC format** — `idle_in_transaction_session_timeout` value format changed between PG versions; AI corrected it
3. **Lambda Linux packaging** — psycopg2 binary must be Linux-compiled; AI switched to `psycopg2-binary` with correct platform target

---

## The 3 Judgment Calls

These were given as realistic production scenarios — the kind a DBRE gets paged for.

### JC1 — Replication Lag: Should I Rebuild the Standby?
**Score: 8/10**

*Scenario: Standby is 3h47m behind. DBA asks: should I rebuild it?*

**What AI got right:**
- Correctly said: don't rebuild, let it catch up
- Gave solid diagnostic queries (`pg_stat_replication`, WAL lag)
- Identified the likely cause correctly

**What AI missed:**
- Never asked: *"Is this your only replica?"*
- Never said: *"Your RPO is already breached at 3h47m. Who needs to know?"*
- No escalation trigger. No awareness that WAL segments might be about to recycle.

---

### JC2 — Migration Safety: ALTER COLUMN on 200M Rows in 2 Hours?
**Score: 9/10**

*Scenario: Developer wants to ship ALTER COLUMN TYPE on a 200M-row table. You have 2 hours.*

**What AI got right:**
- Blocked it immediately
- Connected the replication lag context from JC1 (impressive)
- Gave the correct options table (pg_repack, shadow table, multi-phase)

**What AI missed:**
- Never gave the developer a **concrete safe path to ship today**
- Stopped at "here are your options" — a real DBRE picks one and says "do this"

---

### JC3 — 3 AM Call: Failover to 4-Hour-Lagged Replica?
**Score: 9/10**

*Scenario: Primary is degraded. Manager wants to failover to the replica that's 4 hours behind. It's 3 AM.*

**What AI got right:**
- "Do not failover. Your manager is wrong." — Correct call.
- Gave the right queries to assess primary health
- Explained the data loss consequences clearly

**What AI missed:**
- Never said: *"Don't make this decision alone at 3 AM. Wake someone up."*
- No escalation protocol. No mention of incident management.
- The missing step is the one that gets engineers fired.

---

## The Security Audit: Checkov Results

**Tool:** `checkov -d terraform/` — static analysis against AWS security best practices.

**Result: 36 passed, 30 failed**

---

### What AI Got Right (36 checks passing)

| Area | What was correct |
|------|-----------------|
| IAM | No `AdministratorAccess`, no `*` in actions, no IAM full access policy |
| Secrets | No hardcoded credentials in provider or Lambda env vars |
| SSM | All 5 params as `SecureString` — not plaintext |
| CloudWatch | All alarms have `alarm_actions` enabled |
| RDS | Backup retention set, modern CA cert, Performance Insights KMS |
| Networking | No SSH (22), RDP (3389), or HTTP (80) open from 0.0.0.0/0 |
| Lambda | No CORS policy, not deprecated runtime |

---

### What AI Missed (30 failures — categorized)

#### RDS Hardening (11 failures)
| Check | Issue | Severity |
|-------|-------|----------|
| CKV_AWS_16 | `storage_encrypted` not set — data at rest unencrypted | High |
| CKV_AWS_17 | `publicly_accessible = true` — DB exposed to internet | High |
| CKV_AWS_161 | IAM database authentication not enabled | Medium |
| CKV2_AWS_69 | `rds.force_ssl = 1` missing — SSL not enforced | High |
| CKV_AWS_129 | No `enabled_cloudwatch_logs_exports` — no audit trail | Medium |
| CKV_AWS_118 | Enhanced monitoring disabled — no OS-level metrics | Low |
| CKV_AWS_353 | Performance Insights disabled | Low |
| CKV_AWS_226 | `auto_minor_version_upgrade` not set | Low |
| CKV_AWS_293 | `deletion_protection = false` (intentional for dev) | Dev trade-off |
| CKV_AWS_157 | `multi_az = false` (intentional for dev cost) | Dev trade-off |
| CKV2_AWS_60 | `copy_tags_to_snapshot` not set | Low |

> **Note:** `publicly_accessible = true`, `deletion_protection = false`, and `multi_az = false` are *intentional* for this dev/demo environment. In production, these would be flipped.

#### Lambda Gaps (6 failures)
| Check | Issue | Severity |
|-------|-------|----------|
| CKV_AWS_117 | Lambda not inside VPC — no network isolation | Medium |
| CKV_AWS_116 | No Dead Letter Queue — failed invocations silently lost | Medium |
| CKV_AWS_50 | No X-Ray tracing | Low |
| CKV_AWS_115 | No reserved concurrency limit | Low |
| CKV_AWS_272 | No code signing | Low |
| CKV_AWS_355/290 | IAM logs/ec2 actions use `Resource = "*"` | Medium |

> **The Lambda-outside-VPC issue connects to the slide:** "Rotation Lambda outside VPC — silently fails." No VPC = Lambda reaches SSM over public internet. If SSM endpoint policy restricts VPC-only access, the function fails silently.

#### Networking (5 failures)
| Check | Issue | Severity |
|-------|-------|----------|
| CKV_AWS_382 | Egress `0.0.0.0/0 port -1` — unrestricted outbound | Medium |
| CKV_AWS_130 | Both subnets `map_public_ip_on_launch = true` | Low |
| CKV_AWS_23 | Security group and rules have no `description` | Low |
| CKV2_AWS_11 | No VPC flow logs — no network audit trail | Medium |
| CKV2_AWS_12 | Default VPC security group not restricted | Low |

#### Encryption at Rest (6 failures)
| Check | Issue | Severity |
|-------|-------|----------|
| CKV_AWS_26 | SNS topic has no KMS encryption | Low |
| CKV_AWS_337 (×5) | SSM parameters not using KMS CMK (using AWS default key) | Low |

---

### The Security Gap Summary (from the slides)

The checkov output confirms exactly what the slides predicted under "What AI Cannot Do":

1. **No separate DB users** — Lambda, application, and monitoring all use the master `postgres` user. If Lambda is compromised, the attacker has full DB access.
2. **No pgaudit** — You cannot prove who deleted rows. No forensic trail.
3. **ssl = require not enforced** — `rds.force_ssl = 1` is missing from the parameter group. Connections can succeed over unencrypted channels.
4. **Lambda outside VPC** — The function reaches SSM over the public internet. In a hardened environment with VPC endpoint policies, this silently breaks.

**AI generated the infrastructure. The DBRE is responsible for it.**

---

## The Verdict

### What AI Does Well (~60% of DBRE work)
- Terraform scaffolding: VPC, RDS, IAM, SSM, monitoring — minutes, not days
- Parameter group tuning: all 6 GUCs correct first try
- Application logic: bloat detection, migration pattern matching
- Self-correction: 3 bugs fixed without being asked
- Pattern-based judgment: 8–9/10 on production scenarios

### What AI Cannot Do (the 2 points that cause outages)
1. **Ask the question behind the question** — "Is this your only replica?" "What's your RPO?" "Are WAL segments about to recycle?" AI answers what you asked. A DBRE asks what you didn't know to ask.
2. **Own the security gaps** — AI generated the infrastructure. Nobody told it to enforce SSL, create separate users, or add pgaudit. The DBRE is accountable for what gets deployed.
3. **Know YOUR database** — AI has no idea that `orders.amount` is what finance reconciles end-of-month, or that the CEO demo runs at 3 PM, or which tables are in compliance scope.
4. **Make the call alone at 3 AM** — The missing 2 points from the judgment calls are exactly the 2 points that turned a GitLab maintenance window into an 18-hour outage.

---

## The Real Answer

> **AI removed the 3 weeks of mechanical work. The DBRE now spends all their time on the calls that matter.**

| Before AI | After AI |
|-----------|----------|
| 3 weeks to build infra | 25 minutes |
| Time spent on boilerplate | Time spent on judgment calls |
| Checkov gaps go unfound | `checkov -d terraform/` in 30 seconds |
| Documentation written manually | AI drafts it, DBRE owns it |

The DBRE role doesn't disappear. It upgrades. The mechanical work that consumed 60% of the role is automated. The 40% that required deep PostgreSQL knowledge, system design thinking, and 3 AM judgment — that's what's left. And it's the 40% that actually matters.

---

## Repository Structure

```
dbre-mini/
├── terraform/
│   ├── main.tf          # Provider + KMS
│   ├── vpc.tf           # VPC, subnets, IGW, route table, SG
│   ├── rds.tf           # RDS PostgreSQL 17 + parameter group
│   ├── lambdas.tf       # IAM + Lambda (bloat monitor)
│   ├── ssm.tf           # 5 SSM SecureString parameters
│   ├── monitoring.tf    # SNS + 2 CloudWatch alarms
│   ├── variables.tf     # db_password, aws_region, alert_email
│   └── outputs.tf       # Endpoint, connection string
├── lambdas/
│   └── bloat_monitor/
│       └── lambda_function.py   # SSM → RDS → pg_stat_user_tables
├── tools/
│   └── migration_checker.py     # SQL safety scanner (5 rules)
└── tests/
    ├── test_connection.py        # 6/6 — RDS reachable, PG17 confirmed
    ├── test_parameter_group.py   # 6/6 — all GUCs verified
    ├── test_bloat_monitor.py     # 5/5 — Lambda end-to-end
    └── test_migration_checker.py # 6/6 — V001 PASS, V002 BLOCK
```

---

*labs.postgreshelp.com — Production PostgreSQL Training*
