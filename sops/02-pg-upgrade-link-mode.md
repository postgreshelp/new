# SOP 02 — `pg_upgrade` link mode (`--link`)

## Purpose and key risk
Link mode hard-links relation files instead of copying them. It can substantially reduce upgrade time and extra disk consumption, but it couples the old and new clusters to the same underlying files. Once the new cluster is started, changes can make the old cluster unsafe to use as rollback. Treat a verified independent backup/snapshot as mandatory.

## Preconditions
All SOP 01 prerequisites apply. Additionally:
- Source and target data directories must be on a filesystem supporting hard links and the required paths must permit them.
- Check filesystem/mount layout and tablespace locations; do not assume all relation files are on the same filesystem.
- Rollback owner explicitly accepts the link-mode risk.
- Take a recoverable physical backup or storage snapshot independent of the hard-linked files.

## Procedure
1. Complete the inventory, extension installation, config capture, backup and restore rehearsal from SOP 01.
2. Stop all app writes, jobs, poolers that can write, and source cluster:
```bash
"$OLD_BIN/pg_ctl" -D "$OLD_DATA" -m fast -w stop
```
3. Run check mode. Do not pass `--link` to check mode unless the exact version's docs require/support it; verify the installed version's documented syntax:
```bash
"$NEW_BIN/pg_upgrade" --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
  --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
  --old-port="$OLD_PORT" --new-port="$NEW_PORT" --check
```
4. Execute with link mode:
```bash
"$NEW_BIN/pg_upgrade" --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
  --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
  --old-port="$OLD_PORT" --new-port="$NEW_PORT" --link \
  2>&1 | tee "$LOG"
```
5. Do **not** start the old cluster after the link-mode upgrade has been completed. Do not start target until you have reviewed successful completion and the intended next action.
6. Start the target on its designated port using the target version's service manager or:
```bash
"$NEW_BIN/pg_ctl" -D "$NEW_DATA" -o "-p $NEW_PORT" -w start
```
7. Run the post-upgrade validation, analyze scripts, extension checks, application tests and monitoring from SOP 01.

## Rollback decision
- Before target is started, a documented recovery route may still be possible, but do not assume it; consult the exact version's docs and inspect state.
- After target startup/writes, do not start the old cluster against linked relation files. Restore the independent pre-upgrade backup/snapshot to a separate location, or follow a tested vendor-supported recovery plan.
- Copy mode is usually preferable when preserving the old cluster as a simple rollback option is more important than speed/disk.

## Validation evidence
Record filesystem/mounts (`findmnt`, `df -T`), backup ID, `pg_upgrade` log, target version, extension list, database/object checks, application smoke tests, and sign-off.

## Troubleshooting
- **Hard-link operation not permitted / cross-device link:** target/source relation files or tablespaces cross filesystems or mount options prevent links. Use copy mode or redesign filesystem placement after testing.
- **Insufficient room despite link mode:** WAL, temp files, new objects and tablespace behavior still consume space. Ensure headroom.
- **Rollback uncertainty:** stop and restore the independent backup into an isolated path; never experiment by starting both clusters.
