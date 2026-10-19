# PostgreSQL DBA SOP Bundle

**Purpose:** hands-on, change-controlled runbooks for major-version upgrades, logical replication, backup/restore edge cases, and extension operations.

## Contents
1. `sops/01-pg-upgrade-copy-mode.md` — `pg_upgrade` with copy mode
2. `sops/02-pg-upgrade-link-mode.md` — `pg_upgrade --link`
3. `sops/03-pg-upgrade-custom-tablespaces.md` — custom tablespaces
4. `sops/04-pg-upgrade-physical-replica.md` — physical standby/replica with copy and link workflows
5. `sops/05-pg-upgrade-custom-extensions.md` — extension compatibility and upgrade
6. `sops/06-pg-upgrade-logical-replication.md` — logical subscribers/publishers and major upgrade
7. `sops/07-logical-replication-end-to-end.md` — sample data, limitations, workarounds, cutover and upgrade
8. `sops/08-pgdump-toast.md` — TOAST-backed data dump/restore validation
9. `sops/09-pgdump-large-objects.md` — PostgreSQL large objects (PDF/TXT binaries)
10. `sops/10-top-10-extensions.md` — ten useful extensions: install, create, operate, validate
11. `scripts/` — reusable SQL and shell examples.

## Important scope and safety
- These are operational templates. Confirm exact source and target major versions, OS, package paths, extension packages, replication topology, and vendor support matrix before production use.
- `pg_upgrade` is for major-version upgrades. Minor upgrades normally use package replacement/restart procedures appropriate to the distribution.
- Read the documentation for the exact installed major version before execution. Option availability and replication behavior can change between releases.
- Never run a production upgrade without a tested backup, restore rehearsal, monitoring, a maintenance window, and a rollback decision.
- Link mode is destructive to the rollback path: after the new cluster is started and writes occur, the old cluster's data files may no longer be a valid fallback. Preserve a physical backup/snapshot before using link mode.
- Do not run source and target servers simultaneously against the same data directory or port.
- Commands use example paths `/var/lib/pgsql/OLD/data` and `/var/lib/pgsql/NEW/data`; replace them deliberately. Avoid blind search/replace in production scripts.

## Recommended lab baseline
Linux with PostgreSQL client/server binaries for both majors installed in separate paths; source cluster on port 5432; target cluster on port 5433; dedicated OS account `postgres`; enough disk for a complete copy-mode target plus backup; root/sudo for package and service operations.

## SOP execution pattern
Prerequisites → environment inventory → backup → baseline evidence → execute → observe → validate → decision/cutover → cleanup. Record command output, timestamps, versions, row counts, extension versions, replication state, and application smoke tests.

## Change record
| Field | Record |
|---|---|
| Change/ticket | |
| Owner / reviewer | |
| Source and target major versions | |
| Maintenance window (timezone) | |
| Backup location and restore test ID | |
| Rollback trigger and owner | |
| Validation evidence location | |
| Final sign-off | |

