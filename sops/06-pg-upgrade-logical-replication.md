# SOP 06 — `pg_upgrade` with logical replication

## Why this needs its own plan
Logical replication objects, slots, publications and subscriptions have version-dependent behavior during major upgrades. Do not assume a publisher's logical slot survives `pg_upgrade`, that a subscriber can connect across all major versions, or that a subscription resumes safely without duplicate/missing changes. Check exact-version documentation for both ends and the chosen upgrade path.

## Inventory on publisher and subscriber
```sql
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate
FROM pg_publication;
SELECT subname, subenabled, subslotname, subpublications
FROM pg_subscription;
SELECT slot_name, plugin, slot_type, database, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;
SELECT * FROM pg_stat_subscription;
```
Some catalog columns vary by version. Use `\d+ pg_publication`, `\d+ pg_subscription`, or the version's catalog docs if a query fails. Subscription connection strings can contain secrets; redact before storing evidence.

## Preferred low-risk choices
**Option A — logical migration to new major:** build a new target-major cluster, create schema/roles/extensions, create publications/subscriptions, perform initial copy and catch up, then controlled cutover. This is the best fit when downtime must be minimized and the schema/feature limitations are acceptable. See SOP 07.

**Option B — in-place `pg_upgrade`:** use the documented exact-version workflow, with subscriptions/slots handled as instructed. Take independent backups and rehearse with realistic slot lag and data volume. A successful `pg_upgrade` does not itself prove the logical topology is healthy.

## In-place checklist
1. Freeze schema changes and extension changes.
2. Record publications, subscriptions, slot names/plugins, replica identity, sequence values, and table membership.
3. Confirm target-major supports the logical replication feature set used by the source and downstream systems.
4. Review target-version `pg_upgrade` release notes for logical slot/subscription preservation or invalidation and required post-upgrade commands. If uncertain, assume slots must be recreated and plan a resynchronization.
5. Stop or disable subscriptions/publishers only using a tested, version-appropriate plan. Do not blindly `DROP SUBSCRIPTION`; dropping a subscription may attempt to contact the publisher to remove a slot and may fail when the publisher is unavailable.
6. Run `pg_upgrade --check`, then upgrade publisher/subscriber according to an approved topology order. Avoid upgrading one side while application writes continue unless the exact-version compatibility and data flow are proven.
7. Start upgraded cluster with logical replication deliberately disabled if required by the runbook, then validate data and metadata before enabling subscriptions.
8. Recreate/reconcile slots and subscriptions as documented; confirm initial table synchronization state and `pg_stat_subscription`.
9. Validate counts/checksums, apply lag, sequences, conflict logs, and application reads/writes.
10. Cut over traffic only after all downstream consumers are accounted for.

## Critical gotchas
- Logical replication does not replicate DDL automatically.
- Sequences are not replicated as normal table changes; synchronize sequence state at cutover.
- Large objects are not replicated by built-in logical replication.
- Tables without replica identity generally cannot support UPDATE/DELETE publication.
- Generated/identity columns, partitioned tables, row filters, column lists, schema changes and origin filtering vary by version; check release notes.
- Triggers and constraints on subscribers can change outcomes; subscriber-side triggers may fire depending on configuration/version.
- A logical replication slot retains WAL; monitor `pg_wal` and disk.
- Replication slots are not a substitute for backups.

## Validation SQL
```sql
SELECT subname, pid, received_lsn, latest_end_lsn, latest_end_time
FROM pg_stat_subscription;
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;
```
Use version-specific columns. Compare table counts and business invariants, not only replication status.

## Rollback
Define whether writes are accepted on target before cutover. Once target accepts independent writes, switching back can split the data history. Prefer a read-only validation phase and explicit write-freeze/cutover. Keep a reconciliation plan for any dual-write window; avoid dual writes unless designed for idempotency and conflict handling.
