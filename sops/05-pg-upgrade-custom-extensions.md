# SOP 05 — `pg_upgrade` when custom or third-party extensions are installed

## Objective
Upgrade a cluster without losing extension objects, C libraries, SQL installation scripts, control files, or extension-specific data migrations.

## Inventory source extensions
Run in every database:
```sql
SELECT current_database(), e.extname, e.extversion, n.nspname
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
ORDER BY 1,2;
```
Also inventory extension packages and libraries at OS level. `pg_extension` shows installed database extensions, not every library loaded through `shared_preload_libraries` or custom functions.

## Compatibility matrix
For every extension record:
- Source extension version and source PostgreSQL major supported.
- Target-major package/build available and supported.
- Target extension version and upgrade path (`ALTER EXTENSION ... UPDATE` path).
- Shared library ABI and dependent OS libraries.
- Preload requirements, GUC changes, background workers, hooks, custom types/operators/opclasses.
- Backup/restore or extension-specific migration instructions.
- Vendor/community support statement and rollback method.

Do not assume extension binary compatibility across major versions. Build/install the extension separately for the target major using its supported source/package. Never copy a `.so`/`.dll` from the old major into the new installation as a shortcut.

## Pre-upgrade
1. Install target-major extension packages on every database host that may run the new cluster.
2. Confirm target control and SQL files exist in the target installation's `share/extension`.
3. If extension documentation requires upgrading the extension in the source cluster before `pg_upgrade`, do that only after rehearsal and backup.
4. Remove/resolve unsupported extensions only using the extension vendor's documented procedure; preserve data and dependencies.
5. Check `shared_preload_libraries`, `session_preload_libraries`, `local_preload_libraries`, `dynamic_library_path`, and custom GUCs. Build target configuration deliberately rather than copying blindly.
6. Run `pg_upgrade --check`; address every extension/library blocker.

## Upgrade and post-upgrade
Execute SOP 01 or 02. After target starts:
```sql
SELECT e.extname, e.extversion, n.nspname
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
ORDER BY 1;
```
This reports installed versions; it does not automatically update all extensions to latest. For each extension, review valid upgrade path:
```sql
ALTER EXTENSION extension_name UPDATE;
-- Or, when vendor documents a specific target:
-- ALTER EXTENSION extension_name UPDATE TO 'target_version';
```
Use actual extension identifiers and approved target versions. Execute separately in each database where installed. Some extensions need manual data migration or a sequence of version updates.

## Test matrix
- Extension objects exist and expected schema is correct.
- C functions load successfully; run one representative function per extension.
- Indexes using extension opclasses/operators remain valid; `REINDEX` only if required by extension/version notes.
- Preload configuration starts cleanly; inspect logs for missing symbols, ABI failures and worker errors.
- Application queries, backup/restore, replication and failover paths pass.
- Validate `pg_dump`/`pg_restore` compatibility for extension-owned objects.

## Failure response
If `CREATE EXTENSION` or function calls fail, do not drop extension objects reflexively. Install the matching target-major package/library, verify `ldd` dependencies and `pg_config --pkglibdir`, then follow vendor repair steps. For unsupported extensions, restore the source cluster or use a documented migration path.

## Common extension categories
Examples often used by DBAs include `pg_stat_statements`, `auto_explain`, `pgcrypto`, `btree_gin`, `btree_gist`, `postgres_fdw`, `dblink`, `pg_trgm`, `hstore`, and `uuid-ossp`. Availability and packaging vary by distribution.
