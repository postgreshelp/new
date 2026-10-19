# SOP 04 — Major upgrade when physical replicas exist

## Key principle
`pg_upgrade` upgrades a local cluster's data directory; it does not magically upgrade an entire physical replication topology. Physical replication is major-version-specific and a standby of the old major cannot simply follow a new-major primary. Plan primary and each standby explicitly. Confirm exact-version support for standby upgrade methods before relying on them.

## Inventory
Capture:
```sql
SELECT pg_is_in_recovery();
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;
SELECT slot_name, slot_type, active, restart_lsn
FROM pg_replication_slots;
```
On each standby, record `pg_is_in_recovery()`, `pg_last_wal_receive_lsn()`, `pg_last_wal_replay_lsn()`, timeline, version, data path, archive status and backup ID. Confirm synchronous-commit policy and failover tooling (Patroni/repmgr/custom).

## Strategy selection
- **Copy mode:** safer for preserving the old primary/standby data for rollback; needs disk and still requires rebuilding/upgrading standbys for the new major.
- **Link mode:** faster but the old cluster's relation files become unsafe for rollback after new-cluster startup/writes. Independent backups/snapshots are mandatory.
- **Standby reuse optimization:** some PostgreSQL versions document a way to upgrade standbys by reusing primary-upgrade output. It is version-specific and has prerequisites; do not assume it applies. Consult the installed target version's `pg_upgrade` documentation and rehearse it. Otherwise take a new-major base backup from the upgraded primary after cutover.

## Recommended conservative runbook
1. Freeze DDL and extension changes; announce maintenance.
2. Verify all standbys healthy and caught up. Record replication lag and archive health.
3. Take and restore-test independent physical backup/snapshots of primary and all tablespace volumes.
4. Disable automated failover temporarily using the HA product's documented maintenance procedure. Do not improvise Patroni/repmgr commands.
5. Stop writes at application/pooler layer. Resolve prepared transactions and replication-slot/subscription blockers per target docs.
6. Stop primary and all old-major standbys cleanly, or follow the exact version's supported process if using an in-place standby upgrade optimization.
7. Upgrade primary with SOP 01 (copy) or SOP 02 (link), including tablespaces/extensions.
8. Start target primary isolated from application writes. Validate target cluster.
9. Rebuild each standby for the target major from a fresh target-major base backup unless a supported and rehearsed standby-upgrade method applies. Example conceptual command, adjust options/paths:
```bash
# Run on standby host as postgres; target data directory must be empty.
"$NEW_BIN/pg_basebackup" -h NEW_PRIMARY_HOST -p NEW_PORT \
  -D "$NEW_DATA" -U replication_user -X stream -P -R
```
Use secure `.pgpass` or another approved credential method; don't put passwords on command lines. Configure `primary_conninfo`, TLS, `restore_command`, slots and service manager as required.
10. Start standbys and verify:
```sql
-- On standby
SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
-- On primary
SELECT application_name, state, sync_state, replay_lsn
FROM pg_stat_replication;
```
11. Restore HA automation, verify leader/replica roles and perform a controlled failover test only if approved.
12. Re-enable app writes and monitor.

## Logical replication caution
If a physical replica is also a logical publisher/subscriber, handle logical slots/publications/subscriptions separately; their upgrade behavior is not equivalent to physical streaming replication. Follow SOPs 05–07.

## Rollback
Before target accepts writes, a planned return to old primary may be possible if old cluster remains intact and no topology divergence exists. After target writes, rollback requires reconciliation or restore. Do not connect old-major standbys to the new-major primary or start an old cluster against link-shared files.

## Pass criteria
Primary and every standby are on intended major version; streaming is healthy; sync policy is correct; WAL archive/backup is verified; failover manager sees correct topology; application tests and a controlled HA test pass.
