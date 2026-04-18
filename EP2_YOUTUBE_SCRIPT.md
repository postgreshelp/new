# Episode 2: Can AI Replace a DBRE?
## YouTube Narrative Script

**Format:** Live demo + commentary  
**Runtime:** ~20–25 minutes  
**Tone:** Honest, practical, technical — no hype, no fear

---

## COLD OPEN (0:00–1:00)

**[Show terminal or AWS console in background]**

"In 2017, a GitLab engineer deleted 300 gigabytes of production data during a routine maintenance window.

Not a hack. Not a sophisticated attack. A tired engineer, the wrong server, and a `rm -rf` that finished before anyone could stop it.

The outage lasted 18 hours. They had to restore from a 6-hour-old backup — and even that almost failed, because nobody had validated it.

The engineer had the knowledge. He just didn't have the automation, the guardrails, or the second set of eyes.

So the question I'm asking today is: could AI have built what was missing?

I'm going to give Claude Code — Anthropic's AI coding agent — one prompt. We'll deploy real infrastructure to AWS. Run real tests. Then I'll give it three production scenarios that require actual judgment.

And at the end, I'm going to run a security scanner on everything it built — and we'll see exactly where the gaps are.

Let's find out."

---

## ACT 1 — THE SETUP (1:00–4:00)

**[Show slide: The Experiment]**

"Here's the experiment structure.

I'm going to give AI one prompt — a realistic DBRE task — and time how long it takes to go from nothing to a deployed, tested stack.

For comparison: a human DBRE doing this from scratch — VPC, RDS, Lambda, tests, documentation — that's 2 to 3 days. And that's someone who knows what they're doing.

AI gets 25 minutes.

What I'm building is a mini DBRE tooling stack. This is the kind of thing a database reliability engineer would build to keep production Postgres healthy:

- VPC and subnets on AWS
- RDS PostgreSQL 17 — the latest version
- A Lambda function that monitors table bloat
- SSM Parameter Store for credential management
- CloudWatch alarms for CPU and connections
- A migration safety checker that blocks dangerous SQL
- And Python tests that validate every piece of it — against real AWS

Everything is in Terraform. Everything is real. No mocks. No localhost.

Let's run the prompt."

---

## ACT 2 — THE PROMPT AND BUILD (4:00–8:00)

**[Show Claude Code terminal — scroll through the generation]**

"I'm not going to show you the exact prompt because I didn't save it — but it was essentially: build me a production-grade PostgreSQL tooling stack on AWS. Here's what I want: VPC, RDS 17, Lambda bloat monitor, SSM credentials, CloudWatch alarms, migration safety checker, Python tests. Go.

Watch what happens.

**[Let the generation play for a moment]**

It starts with the Terraform. VPC first — that's the right order. Then the RDS parameter group with the GUCs I want. Then the Lambda. Then the tests.

Here's something I want you to notice — it's making architectural decisions on its own.

**[Point to subnet creation]**

When it tries to create the RDS, it fails — because RDS subnet groups require subnets in at least two Availability Zones. I didn't tell it that. It figured it out from the error, added a second subnet in a second AZ, and kept going. No prompt from me.

That's self-correction number one.

**[Point to parameter group values]**

Self-correction number two happens here — the GUC format for `idle_in_transaction_session_timeout` changed between Postgres versions. The value format that worked on PG14 fails on PG17. AI caught the error, looked up the correct format, and fixed it.

**[Point to Lambda packaging]**

Self-correction number three — psycopg2, the Python Postgres library, needs to be compiled for Linux when it runs in Lambda. If you just pip install it on Windows or Mac, it'll fail silently in the cloud. AI switched to the correct platform target automatically.

Three bugs. Three self-corrections. I did nothing.

Total time from prompt to deployed and tested: 25 minutes."

---

## ACT 3 — THE TEST RESULTS (8:00–13:00)

**[Show test output in terminal — 4/4 green]**

"Let me show you the test results. These are running against real AWS. Real RDS. Real Lambda. Real SSM.

**Test 1 — Connection and Version**

`[Show output scrolling]`

Six checks. RDS reachable — pass. PostgreSQL 17.6 confirmed — the actual server version string — pass. `pg_stat_statements` loaded — pass. All six green.

This is not a mock. That's the actual endpoint returning the actual version.

**Test 2 — Parameter Group**

All six GUCs verified. `idle_in_transaction_session_timeout` at 300 seconds. `statement_timeout` at 60 seconds. `log_min_duration_statement` at 1 second. Six for six.

This is what takes a human engineer 2 hours to set up correctly — looking up the right GUC names, the right units, testing that they actually applied. Done.

**Test 3 — Bloat Monitor Lambda**

`[Show Lambda invocation result]`

Lambda fires. It pulls credentials from SSM — host, port, username, password, database name. It connects to RDS. It queries `pg_stat_user_tables`.

And look at this result: 50.0% dead tuple ratio on a seeded table. CRITICAL classification. Detected and reported correctly.

That's the full path: Lambda → SSM → RDS → PostgreSQL stats → structured JSON result. End to end. Five for five.

**Test 4 — Migration Checker**

`[Show migration checker output]`

V001 — a clean migration file. No patterns. Result: PASS. Exit code zero.

V002 — a dangerous migration file. I put four problems in it deliberately.

`CREATE INDEX` without `CONCURRENTLY` — caught. Table lock risk.
`ALTER COLUMN TYPE` — caught. Full table rewrite.
`NOT NULL` without `NOT VALID` — caught. Full table scan.
`DELETE FROM orders;` — no WHERE clause — caught. **BLOCKED.**

Exit code 2. Result: BLOCKED.

4 out of 4 tests passing. On real AWS. In 25 minutes."

---

## ACT 4 — THE JUDGMENT CALLS (13:00–18:00)

**[Cut to conversational / talking head — or just terminal with prompts]**

"Okay. So AI can build infrastructure. That's impressive but not surprising. The real question is whether it can make production decisions. The kind of call a DBRE gets paged for at 3 AM.

I gave it three scenarios. I'll score each one.

---

**Judgment Call 1: Replication Lag. Should I rebuild the standby?**

Scenario: Your replica is 3 hours and 47 minutes behind. The DBA asks you — should we rebuild it?

AI's answer: Don't rebuild. The standby is catching up. Here are the diagnostic queries to confirm.

That's correct. I scored it 8 out of 10.

Here's the 2 points it lost: it never asked — is this your ONLY replica? If this is the only standby and you're 3h47m behind, your recovery point objective is already breached. Who needs to know about that? Your CTO? Your on-call manager?

AI answered the question you asked. A DBRE asks the question you didn't know to ask.

---

**Judgment Call 2: ALTER COLUMN on 200 million rows. Two-hour window.**

Scenario: A developer wants to ship a TYPE change on a 200M-row orders table. You have 2 hours. Is this safe?

AI's answer: Block it. Here are your options — pg_repack, shadow table, multi-phase migration.

9 out of 10. It even connected this to the replication lag from JC1 — which is impressive.

Here's the 1 point it lost: it stopped at 'here are your options.' A real DBRE picks one and says 'do this: here's the exact SQL, here's the timing, here's what to tell the developer.'

The developer needs a path to ship today. Not a menu.

---

**Judgment Call 3: 3 AM failover. Manager says go. Replica is 4 hours behind.**

This is the critical one. Primary is degraded. Your manager is on the phone, half-asleep, saying to failover. But the replica is 4 hours behind. That means you'd lose 4 hours of transactions.

AI's answer: Do not failover. Your manager is wrong.

That's the correct call. 9 out of 10.

The 1 point it lost: it never said — don't make this decision alone at 3 AM. Wake someone up. Get your DBA lead on the call. Document your reasoning before you act.

GitLab's engineer would have scored 9 out of 10 on a quiz. He just didn't ask the right question before running the command.

The missing 2 points are the ones that cause 18-hour outages.

---

**What does this mean?**

AI gets you to 8 or 9 out of 10 on hard production calls. The 1 or 2 it misses are:
- The context you carry in your head about your specific system
- The escalation instinct — knowing when not to act alone
- The question behind the question

Those gaps are small. But in production, small gaps at 3 AM are exactly what causes disasters."

---

## ACT 5 — THE SECURITY AUDIT (18:00–22:00)

**[Show checkov running in terminal]**

"Now here's the part I think is most honest about this whole experiment.

I'm going to run Checkov on everything AI built. Checkov is a static security scanner for Terraform. You point it at your infrastructure code, it runs in 30 seconds, and it tells you where your configuration violates AWS security best practices.

`checkov -d terraform/`

`[Let it run — show the spinning progress]`

Result: 36 checks passed. 30 failed.

Let me show you both sides of this.

**What AI got right:**

`[Point to passing checks]`

No hardcoded credentials — pass. SSM SecureString for all 5 database parameters — pass. IAM roles scoped correctly — pass. No SSH or RDP open from the internet — pass. CloudWatch alarm actions enabled — pass.

This is the baseline hygiene. AI got it right.

**What AI missed:**

`[Show first major failure]`

RDS storage is not encrypted at rest. `storage_encrypted` is not set. That's a high-severity finding. In production, any data written to this instance is sitting unencrypted on disk.

`[Show publicly_accessible]`

`publicly_accessible = true`. The database is reachable from the public internet on port 5432. In this dev environment, that's intentional — we need to connect to it. But AI didn't call that out. It didn't say 'I'm setting this to true for dev access — change it before production.'

`[Show ssl enforcement]`

This one is on the slides: `rds.force_ssl = 1` is missing from the parameter group. SSL is not enforced. A client can connect without encryption and it will succeed.

`[Show Lambda findings]`

Lambda is not inside the VPC. That means Lambda reaches SSM over the public internet. If you add a VPC endpoint policy that restricts access to VPC-only, this Lambda silently breaks. No error. No alarm. It just fails.

`[Show IAM wildcard]`

The IAM policy for Lambda uses `Resource = *` for CloudWatch Logs writes. That means the Lambda role can write to any log group in the account. Scoped incorrectly.

**The summary:**

AI generated the infrastructure. 36 of 66 security checks pass right out of the box. That's not bad. But the 30 that fail — storage encryption, SSL enforcement, public access, Lambda isolation, IAM scoping — those are the gaps that become incident reports.

The DBRE is responsible for everything in that Terraform. Not the AI.

---

**And here's what the slides say about what AI truly missed — beyond checkov:**

No separate database users. Lambda connects as `postgres` — the master user. If that Lambda function is compromised, the attacker has full database access. A DBRE would have created a read-only `lambda_monitor` user with access to exactly `pg_stat_user_tables`.

No pgaudit. You cannot prove who deleted rows from the orders table. No forensic trail. If compliance asks you to show every write to a sensitive table, you have nothing.

AI generated it. Nobody told it to add those. That's not a failure of the tool — that's the reality of what 'AI built this' means in practice."

---

## CLOSE (22:00–25:00)

**[Calm, direct — no hyperbole in either direction]**

"So what's the actual answer?

AI did not replace the DBRE. Not even close.

But here's what it did do: it replaced about 3 weeks of mechanical work. The scaffolding. The Terraform boilerplate. The parameter group lookup. The Lambda packaging. The test structure. All of that — gone. 25 minutes.

What's left is the part that actually matters. The judgment calls. The security ownership. The knowledge of your specific system. The question behind the question at 3 AM.

That 40% of the job that no quiz can test — that's what the DBRE does now. Full time. The other 60% is automated.

Here's what I'd tell any DBA or DBRE watching this:

Don't be afraid of this tool. Use it. Let it write the Terraform. Let it generate the tests. Let it draft the runbooks. Then you review it, you own it, you audit it with checkov, and you sign your name to it.

Because in the end, the question isn't 'can AI replace a DBRE.' The question is: will the DBRE who uses AI replace the DBRE who doesn't?

If you want to try this yourself — all the scripts are in the description. Deploy it, test it, run checkov on it, destroy it. See what AI generates for your AWS account.

And if you want to build the knowledge that AI can't replace — the WAL internals, the lock anatomy, the pg_stat_replication deep dives — that's at postgreshelp.com.

Episode 3 is coming. Subscribe so you don't miss it.

See you then."

---

## B-ROLL / VISUAL SUGGESTIONS

| Timestamp | Visual |
|-----------|--------|
| 0:00–1:00 | Terminal with blinking cursor / GitLab incident headline |
| 1:00–4:00 | Slide: The Experiment — side by side DBRE vs AI timings |
| 4:00–8:00 | Claude Code terminal — generation in real time |
| 8:00–13:00 | pytest output — 4 test suites — all green |
| 13:00–18:00 | Prompt/response for each judgment call — side by side with score |
| 18:00–22:00 | checkov terminal output — scroll through failures |
| 22:00–25:00 | Talking head or slide: The Real Answer |

---

## THUMBNAIL SUGGESTIONS

**Option A:** Split screen — "25 minutes" (AI) vs "3 days" (Human) with Postgres elephant and AWS logo

**Option B:** Terminal showing `4/4 Tests Passing` with bold text overlay: "AI vs DBRE — Who Wins?"

**Option C:** Red/green checklist — checkov failures highlighted, title: "AI Built This. I Found 30 Problems."

---

## TITLE + DESCRIPTION SUGGESTIONS

**Title options:**
- `I gave AI one prompt to build a PostgreSQL production stack. Here's what checkov found.`
- `AI vs DBRE: 4/4 tests pass, 30 security gaps — the honest breakdown`
- `Can AI replace a Database Reliability Engineer? (Live AWS test)`

**Description hook:**
> GitLab lost 300GB in 2017 because nobody built the automation. I gave Claude Code one prompt to build what they were missing — VPC, RDS PostgreSQL 17, Lambda, tests, monitoring. It passed 4/4 tests in 25 minutes. Then I ran checkov and found 30 gaps. This is the honest breakdown.

---

*labs.postgreshelp.com — Production PostgreSQL Training*
