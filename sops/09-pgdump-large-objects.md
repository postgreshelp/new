# SOP 09 — `pg_dump` / `pg_restore` for PostgreSQL large objects (PDF, TXT, images)

## Background and distinction
PostgreSQL large objects (LOs) use OIDs and internal catalogs such as `pg_largeobject`/`pg_largeobject_metadata`. They are distinct from `bytea` columns and from files stored outside PostgreSQL. `pg_dump` includes large objects by default unless options exclude them; validate behavior for the installed version and chosen dump options. Do not manually dump internal LO catalogs.

## 1. Create test data
Create database and table:
```sql
CREATE DATABASE lo_lab;
\connect lo_lab
CREATE TABLE uploaded_file (
  file_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  file_name text NOT NULL,
  mime_type text NOT NULL,
  lo_oid oid NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
```
Use `lo_import` only on the server host and only when the PostgreSQL OS user can read the file; it is privileged and often unsuitable for application uploads. For a lab:
```sql
-- Server-side file path example; run only if the file exists and permissions are approved.
SELECT lo_import('/var/tmp/sample.pdf') AS oid;
```
For application uploads use libpq large-object APIs (or a trusted application library) within a transaction, then insert the returned OID into `uploaded_file`. Avoid relying on server-side filesystem paths for user-supplied uploads.

Alternative, SQL-only lab generation:
```sql
SELECT lo_create(0) AS oid;
```
`lo_create` creates an empty LO; it does not populate a PDF. Use a client API or `lo_import` for binary content.

## 2. Dump
```bash
pg_dump -Fc -d "host=localhost port=5432 dbname=lo_lab user=backup_user" \
  -f lo_lab.dump
pg_restore -l lo_lab.dump | grep -E 'BLOB|LARGE OBJECT|TABLE DATA'
```
Archive TOC labels vary by version; inspect the complete listing if `grep` returns no match. Do not use `--no-large-objects` when LO content must be migrated.

If you need roles/tablespaces:
```bash
pg_dumpall --globals-only -h source-host -p 5432 -U backup_user > globals.sql
```
Review the globals file for secrets/role attributes before storing it securely.

## 3. Restore
```bash
createdb -h target-host -p 5433 -U restore_user lo_lab_restore
pg_restore -h target-host -p 5433 -U restore_user \
  --verbose -d lo_lab_restore lo_lab.dump
```
Restore to a clean database unless you have reviewed `--clean` behavior. Large object ownership/ACLs may require correct role creation and privileges before/after restore.

## 4. Validate OID references and content
Check application references:
```sql
SELECT count(*) AS references,
       count(DISTINCT lo_oid) AS distinct_los
FROM uploaded_file;
SELECT file_id, file_name, lo_oid
FROM uploaded_file ORDER BY file_id;
```
Use `lo_get(oid)` to retrieve contents on versions where available, but avoid selecting huge binary output into a terminal. For a sample, validate length and digest in SQL:
```sql
SELECT f.file_id, f.file_name, octet_length(lo_get(f.lo_oid)) AS bytes,
       encode(digest(lo_get(f.lo_oid), 'sha256'), 'hex') AS sha256
FROM uploaded_file f
ORDER BY f.file_id;
```
This requires `pgcrypto` for `digest`; `lo_get` availability depends on version. For large objects too large for one in-memory value, use the application's large-object API to stream and compute SHA-256. Compare source and target manifests by stable file ID/name and digest. Verify every OID reference resolves.

## 5. Security and lifecycle
- LO OIDs are identifiers, not access control. Review LO ownership and ACLs; table privileges alone may not express the intended LO access model.
- Consider the `lo` extension's `lo_manage` trigger for cleanup of orphaned large objects when rows are deleted; test its behavior and privileges before production use.
- Never allow untrusted users to choose arbitrary OIDs and read them without authorization checks.
- Keep binary files out of shell history and logs; avoid dumping content to terminal.
- Large objects are not copied by built-in logical replication. Use `pg_dump`/`pg_restore` or a tested binary migration process.

## 6. Troubleshooting
- **References restore but contents missing:** check dump flags, archive contents, `pg_restore` errors, and whether `--no-large-objects` was used.
- **Permission denied on lo_import:** file must be readable by PostgreSQL server OS user and server-side import privilege requirements must be met.
- **Checksum mismatch:** stream bytes and compare SHA-256, check client encoding is irrelevant to raw binary but application transformations may not be.
- **OID conflict/manual import:** do not hand-edit internal LO catalogs; use supported LO APIs.
- **Application cannot access restored object:** verify table grants, LO ACL/ownership, and app API behavior.

## 7. Pass criteria
All references resolve; source/target file counts and byte lengths match; content digests match; ownership/ACL expectations and application download tests pass.
