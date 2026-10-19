# MyBank Aurora PostgreSQL — 2-day lab runbook

Lab-only: public instances, `0.0.0.0/0`, and the password in `env.sh` are deliberate, so students can focus on Aurora concepts.

## How every script behaves

- Each step prints `[OK]`, `[WARN]` or `[ERROR]`.
- Each script **checks its own result**, by connecting with SQL where it can.
- Each script ends with one line: `RESULT: SUCCESS`, `RESULT: FAILED` (with the reason and the line), or `RESULT: CANCELLED — nothing was changed`.
- After the result it prints **`Next:`** with the command(s) to run next.
- Endpoints are always shown with a **copy-paste `psql` command**.
- Scripts ask `[y/N]` before changing anything. Run `LAB_YES=1 bash <script>` to skip the prompts. Teardown asks you to type `DELETE`.
- Scripts are safe to re-run: anything that already exists is reused.
- You need bash 4+ (Linux, or Homebrew bash on macOS), plus the AWS CLI v2 and python3. psql is optional on the laptop; it's needed for the live checks.

## State files: how settings flow

```
env.sh.example --cp--> env.sh   (you edit: region, versions, PGPASSWORD ...)
                         |  sources lib.sh + every *.env below automatically
01-create-network.sh  -> B02-network.env   (VPC, subnets, SG, S3 endpoint IDs)
02-create-cluster.sh  -> endpoints.env     (writer/reader + instance endpoints)
10-rds-proxy.sh       -> proxy.env         (proxy endpoint, proxy SG)
10a-client-ec2.sh     -> client.env        (client EC2 id/IP/SG)  + mybank-lab-key.pem
12-s3-prerequisites.sh-> s3-resources.env  (bucket, role ARNs)
```
You never edit the `*.env` files by hand. `90-teardown.sh` removes them.
**Before you hand the folder to students**, delete `B02-network.env`, `endpoints.env` and any other `*.env` file except `env.sh`, because those contain *your* account's IDs. `00-preflight.sh` detects stale files and tells you so.

## Setup

```bash
cp env.sh.example env.sh
vi env.sh                        # set PGPASSWORD (enables every live check), confirm region/version
bash 00-preflight.sh             # tools, identity, engine version, valid Blue/Green targets
bash 01-create-network.sh        # ~1 min
bash 02-create-cluster.sh        # ~20-25 min; prints psql commands for every endpoint
```

## Day 1: Aurora fundamentals

| Script | What students see | Changes AWS |
|---|---|---|
| `03-status.sh` | Who is writer, promotion tiers, AZs, every endpoint plus psql, live connect | no |
| `16-aurora-vs-onprem.sql` | Familiar PostgreSQL works the same (`psql ... -f 16-aurora-vs-onprem.sql`) | SQL |
| `03b-endpoints.sh demo` / `create` | Reader endpoint spreads connections; custom "reporting" endpoint pinned to one reader | create: yes |
| `04-failover-demo.sh` | Timed failover with a client probe loop; re-runnable (fails back) | yes |
| `04b-scale-instance.sh [class]` | Resize reader → fail over → resize old writer (minimal downtime) | yes |
| `05-parameter-groups.sh` | Cluster vs instance parameter groups, apply status, live `SHOW` | no |
| `05b-param-change.sh` / `reset` | Dynamic change applies at once; static change shows `pending-reboot`, then reboot | yes |
| `06-backup-pitr.sh` | Restorable window and a manual snapshot | yes |
| `06b-clone-pitr.sh clone` | Copy-on-write clone; proves source and clone diverge independently | yes |
| `06b-clone-pitr.sh pitr` | Drop a table "by accident", restore to the second before, rows are back, plus a `pg_dump` command to copy it back | yes |
| `07-security-basics.sh` | Encryption, exposure, SG rules, TLS, `rds_superuser` | no |
| `08-monitoring.sh` | CPU, connections, memory, replica lag per instance; daily SQL | no |
| `08b-insights-logs.sh` | Performance Insights on; slow query found in CloudWatch Logs; `pg_stat_statements` top SQL | yes |
| `09-cost-control.sh` | What is billing now, and the cost levers | no |
| `09b-stop-start.sh stop` | **End of Day 1**: stop compute overnight (`start` next morning) | yes |

## Day 2: Proxy, scaling, S3, Blue/Green

**RDS Proxy.** The proxy endpoint is private, so the demos run on a client EC2 inside the VPC.
```bash
bash 10-rds-proxy.sh             # waits until the target is healthy; explains AUTH_FAILURE / CONNECTION_FAILED
bash 10a-client-ec2.sh create    # t3.micro + psql/pgbench; tests DB access from inside the VPC
bash 10a-client-ec2.sh ssh
# on the EC2:
cd lab
bash 10b-proxy-demo.sh check       # private DNS, backend PID reuse
bash 10b-proxy-demo.sh multiplex   # peak DB connections: direct vs proxy
bash 10b-proxy-demo.sh pinning     # idle vs pinned sessions
bash 10b-proxy-demo.sh failover    # then on the laptop: bash 04-failover-demo.sh
```
Run `bash 10a-client-ec2.sh sync` whenever a script writes a new `*.env` file, so the EC2 gets it.

**Reader auto scaling**
```bash
bash 11-reader-autoscaling.sh            # target 30% CPU, 1-3 readers
bash 11b-autoscale-load.sh load          # on the EC2: pgbench on the reader endpoint
bash 11b-autoscale-load.sh watch         # on the laptop: SUCCESS when application-autoscaling-* joins (~15 min)
bash 11c-serverless-reader.sh add        # optional: db.serverless reader; 'watch' shows ACUs
```

**S3**
```bash
bash 12-s3-prerequisites.sh       # bucket, 2 roles, associations, then RUNS 13-*.sql and verifies import + export
```

**Blue/Green**
1. Register the proxy first: once a deployment exists, AWS blocks registration.
2. No DDL on blue while the deployment exists.

```bash
bash 14-bluegreen-ready.sh        # READY / NOT READY with blockers; creates bg_demo table
bash 15-bluegreen.sh create       # ~20-40 min, waits until AVAILABLE; green runs BG_TARGET_ENGINE_VERSION
bash 15-bluegreen.sh demo         # blue insert shows up on green; write on green refused
bash 15-bluegreen.sh switchover   # prints a probe loop; verifies same endpoint, new version
bash 15-bluegreen.sh cleanup      # handles both cases: before switchover (deletes green) / after (deletes *-old1)
```

## End of course

```bash
bash 00-inventory.sh             # everything that exists ($ = billable)
bash 90-teardown.sh              # deletes it all in order; options: --keep-s3, --keep-network
```

If the VPC deletion warns (proxy/EC2 network interfaces still releasing), re-run teardown after 5 minutes.

## Things students should notice (talking points)

- **Endpoints, not instances.** Instance names don't follow roles after a failover.
- **Readers share the writer's storage.** That's why replica lag is in milliseconds, and a clone is instant copy-on-write.
- **No `postgresql.conf` or `ALTER SYSTEM`.** Parameter groups replace them: cluster-level vs instance-level, dynamic vs static.
- **PITR and snapshot restores always create a new cluster with no instances.** You add an instance yourself.
- **RDS Proxy.** It helps with connection churn and failover. Pinning cancels the benefit. It's reachable only from inside the VPC.
- **Blue/Green uses logical replication.** Tables need primary keys, no DDL is allowed meanwhile, and sequences sync at switchover. The old cluster stays as `*-old1` until you delete it.
