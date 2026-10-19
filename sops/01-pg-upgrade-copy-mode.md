# SOP 01 — Major-version upgrade with `pg_upgrade` copy mode

## 1. Objective and decision
Upgrade an existing PostgreSQL cluster to a newer major version while preserving the old cluster's files. Copy mode is the safer default when rollback time and independent old-cluster data matter; it requires additional disk space and can take longer.

## 2. Preconditions
- Source and target PostgreSQL binaries installed in separate directories.
- Target major version is supported by the installed `pg_upgrade`; check release notes and target-version docs.
- OS user owns both data directories; no concurrent package/service automation will start either cluster.
- All extensions and their target-major shared libraries/control/SQL files are installed before the upgrade.
- Tested backup or storage snapshot; application owners approve downtime.
- Sufficient free space for the new cluster's copied relation files, WAL, temporary work, and safety margin.
- Inventory roles, databases, tablespaces, extensions, collations, locales, prepared transactions, replication slots, publications/subscriptions, and external integrations.

## 3. Example variables (edit and verify)
```bash
export OLD_BIN=/usr/pgsql-16/bin
export NEW_BIN=/usr/pgsql-18/bin
export OLD_DATA=/var/lib/pgsql/16/data
export NEW_DATA=/var/lib/pgsql/18/data
export OLD_PORT=5432
export NEW_PORT=5433
export LOG=/var/tmp/pg_upgrade_copy_$(date +%Y%m%d_%H%M%S).log
```
Use the actual package paths and major versions available in your environment. Confirm paths with `which psql`, package manager queries, and service configuration.

## 4. Inventory and baseline
Run as the database OS owner unless noted:
```bash
"$OLD_BIN/postgres" --version
"$NEW_BIN/postgres" --version
"$OLD_BIN/pg_ctl" -D "$OLD_DATA" status
df -h "$(dirname "$NEW_DATA")"
"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -X -c 'SELECT version(), current_timestamp;'
"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -X -c \
"SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;"
"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -X -c \
"SELECT extname, extversion FROM pg_extension ORDER BY 1;"
"$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -X -c \
"SELECT spcname, pg_tablespace_location(oid) FROM pg_tablespace ORDER BY 1;"
```
Save outputs. Check `pg_controldata "$OLD_DATA"` and verify source cluster is cleanly shut down before the upgrade.

## 5. Backup and rehearsal
1. Take a supported physical backup or storage snapshot.
2. Confirm backup completion and perform a restore rehearsal into an isolated path/host.
3. Capture configuration separately: `postgresql.conf`, `pg_hba.conf`, `pg_ident.conf`, service overrides, TLS files, scripts, cron jobs, monitoring configuration. Do not blindly copy old configuration into the new major version.
4. Record application smoke tests and important row counts/checksums.

## 6. Prepare the target
- Stop target service if it was initialized by packages; ensure no target postmaster is running.
- Create a clean target data directory owned by `postgres`. Do not initialize a cluster over a non-empty directory.
- Configure required locale/encoding/checksum choices to match `pg_upgrade` requirements.
- Install target-major extension packages and any OS libraries.
- Verify `NEW_DATA` is the intended empty directory.

Example:
```bash
sudo install -d -o postgres -g postgres -m 700 "$NEW_DATA"
```
Do not run this command if the path already contains data. Inspect it first.

## 7. Compatibility check
Stop application writes and scheduled jobs, then stop the source cleanly:
```bash
"$OLD_BIN/pg_ctl" -D "$OLD_DATA" -m fast -w stop
```
Run the check mode as `postgres`:
```bash
"$NEW_BIN/pg_upgrade" \
  --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
  --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
  --old-port="$OLD_PORT" --new-port="$NEW_PORT" \
  --check 2>&1 | tee "$LOG"
```
Use the actual `pg_upgrade` option syntax documented for the installed version. Fix every reported blocker and rerun check mode until clean. Do not ignore extension or shared-library incompatibilities.

## 8. Execute copy mode
Copy mode is the default when `--link` is not supplied:
```bash
"$NEW_BIN/pg_upgrade" \
  --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
  --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
  --old-port="$OLD_PORT" --new-port="$NEW_PORT" \
  2>&1 | tee -a "$LOG"
```
Keep the terminal/log output. Do not start the application yet. If the run fails, preserve logs and do not improvise by deleting either data directory.

## 9. Post-upgrade maintenance and validation
- Run the generated `analyze_new_cluster` script if supplied by `pg_upgrade`, or follow target-version guidance to refresh planner statistics. On large systems, schedule this with an agreed performance window.
- Run `vacuumdb --all --analyze-in-stages` if appropriate for the target version and workload; avoid running conflicting maintenance simultaneously.
- Review generated scripts such as `delete_old_cluster`; **do not run cleanup until rollback is formally waived**.
- Validate:
```bash
"$NEW_BIN/psql" -p "$NEW_PORT" -d postgres -X -c 'SELECT version(), current_timestamp;'
"$NEW_BIN/psql" -p "$NEW_PORT" -d postgres -X -c \
"SELECT datname, datallowconn FROM pg_database ORDER BY 1;"
"$NEW_BIN/psql" -p "$NEW_PORT" -d postgres -X -c \
"SELECT extname, extversion FROM pg_extension ORDER BY 1;"
"$NEW_BIN/psql" -p "$NEW_PORT" -d postgres -X -c \
"SELECT count(*) FROM pg_database;"
```
Run application-specific row counts, constraints, sequence checks, critical queries, permissions, scheduled jobs, and extension tests. Review logs for errors and compare latency/plan behavior.

## 10. Cutover
1. Confirm validation checklist signed off.
2. Point service discovery/connection pool/application configuration to the new cluster.
3. Enable application writes in a controlled order.
4. Monitor errors, connections, locks, replication/backup jobs, disk/WAL, latency, and query plans.
5. Keep old cluster stopped and unchanged until rollback window expires.

## 11. Rollback
Before new-cluster writes: stop target, retain evidence, and restart source only after confirming no writes were accepted by target. After target has accepted writes, rollback requires a defined data reconciliation/reverse-migration plan; simply restarting the old cluster loses target-side changes. Copy mode preserves old files but does not automatically synchronize post-cutover writes.

## 12. Troubleshooting
- **Missing library/control file:** install target-major extension package and dependencies; rerun `--check`.
- **Locale/collation warnings:** validate OS locale availability and collation version; plan reindex where required.
- **Insufficient disk:** expand storage or choose a separately assessed strategy; do not switch to link mode casually.
- **Port conflict:** stop target postmaster and verify with `pg_ctl status`/`ss -ltnp`.
- **Permission denied:** inspect ownership and parent directory traversal permissions.
- **Prepared transactions/replication objects:** inventory and resolve per exact-version `pg_upgrade` documentation.

## 13. Pass/fail
**PASS** only when `pg_upgrade` completes, target starts cleanly, critical data/objects/extensions are validated, application smoke tests pass, backup is configured for target, and owner signs off. **FAIL** if any blocker remains or data/application validation is incomplete.
