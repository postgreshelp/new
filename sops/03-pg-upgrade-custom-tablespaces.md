# SOP 03 — `pg_upgrade` with custom tablespaces

## Objective
Upgrade a cluster that stores one or more tablespaces outside the default data directory. Tablespaces contain live relation files; paths, mount points, permissions, capacity and link/copy behavior are critical.

## Inventory
On source:
```sql
SELECT oid, spcname, pg_tablespace_location(oid) AS location
FROM pg_tablespace ORDER BY spcname;
SELECT d.datname, t.spcname
FROM pg_database d CROSS JOIN pg_tablespace t
WHERE t.spcname NOT IN ('pg_default','pg_global')
ORDER BY 1,2;
```
The second query is only a catalog inventory scaffold; to identify actual relations per tablespace, query `pg_class.reltablespace` joined to `pg_tablespace` in each database. Remember that `reltablespace=0` means the database default tablespace.

Capture `df -hT`, `findmnt`, ownership, mount options, symlinks and ACLs for every tablespace path. Confirm backup covers all tablespace data.

## Planning rules
- Every custom tablespace must be accessible to the target cluster with correct ownership and capacity.
- Follow `pg_upgrade` documentation for tablespace handling and target path remapping options for the exact version. Do not invent or assume a `--tablespace-mapping` option; check `pg_upgrade --help` for the installed binary.
- Never point a target tablespace at a live source tablespace directory if the chosen mode could overwrite source data.
- Copy mode needs enough space for copied relation files; link mode requires hard-link-compatible filesystem placement and has rollback risks described in SOP 02.
- Make a path mapping table and get approval before executing.

| Tablespace | Source path | Target path | Filesystem/capacity | Verified |
|---|---|---|---|---|
| `fast_ts` | `/pgdata_ts/fast` | `/pgdata_new_ts/fast` | Record | ☐ |
| `archive_ts` | `/pgarchive_ts/data` | `/pgarchive_new_ts/data` | Record | ☐ |

## Procedure
1. Stop writes and take a backup/snapshot including every tablespace volume.
2. Install target binaries and matching target-major extension packages.
3. Verify target paths are mounted, empty/appropriately prepared per the version's `pg_upgrade` requirements, writable by `postgres`, and not source paths:
```bash
findmnt /pgdata_ts/fast
df -hT /pgdata_ts/fast /pgdata_new_ts/fast
sudo -u postgres test -w /pgdata_new_ts/fast
```
4. Stop source cleanly.
5. Run `pg_upgrade --check` with all path/mapping options exactly as shown by the installed version's `pg_upgrade --help` and official documentation. Preserve output.
6. Execute copy or link mode using the same validated path mapping. Never proceed if a tablespace path warning is unexplained.
7. Inspect the target catalog:
```sql
SELECT oid, spcname, pg_tablespace_location(oid)
FROM pg_tablespace ORDER BY 1;
```
8. For every user tablespace, create a test table in that tablespace and verify `pg_relation_filepath()` resolves under the expected target path. Remove the test object only after evidence is captured.
9. Compare per-database and per-tablespace sizes, object counts, and critical table row counts. Validate all tablespace mount points survive reboot and are mounted before PostgreSQL starts.

## Failure handling
- Missing path or mount: stop target; fix mount and permissions before restarting.
- Wrong path mapping: stop target and do not write application data until corrected. Follow version-specific recovery guidance.
- Capacity shortfall: abort before execution or expand storage; do not delete source files to make room.
- Link mode failure across filesystems: use copy mode unless storage layout is changed and retested.

## Sign-off
Tablespace path map reviewed, all target mounts persistent, backup includes every volume, `pg_upgrade` checks clean, and application read/write tests passed.
