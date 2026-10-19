# SOP 08 — `pg_dump` / `pg_restore` for tables with TOAST data

## Background
TOAST is PostgreSQL's internal mechanism for storing/compressing large variable-length values (for example large `text`, `bytea`, and some JSON values). TOAST tables and indexes are internal implementation details. Dump the logical table/database, not the internal TOAST relation directly. `pg_dump` includes the logical column values and restore reconstructs storage automatically.

## 1. Create a test database and TOAST-heavy table
```sql
CREATE DATABASE toast_lab;
\connect toast_lab
CREATE SCHEMA demo;
CREATE TABLE demo.documents (
  document_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title text NOT NULL,
  body text NOT NULL,
  payload bytea,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
INSERT INTO demo.documents(title,body,payload,metadata)
SELECT 'doc-'||g,
       repeat(md5(g::text), 12000),
       decode(repeat(md5((g*7)::text), 1200), 'hex'),
       jsonb_build_object('id',g,'kind','large','tags',jsonb_build_array('a','b'))
FROM generate_series(1,25) g;
```
Inspect table and TOAST relation:
```sql
SELECT c.oid::regclass AS table_name,
       c.reltoastrelid::regclass AS toast_relation,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c WHERE c.oid='demo.documents'::regclass;
```
Do not write application logic against the generated TOAST table name.

## 2. Logical dump
Use client tools compatible with the source server. For a portable custom archive:
```bash
pg_dump -Fc -d "host=localhost port=5432 dbname=toast_lab user=backup_user" \
  -f toast_lab.dump
pg_restore -l toast_lab.dump > toast_lab.contents
```
Use `.pgpass` or approved secret management; do not put passwords in shell history. For a whole database restore, create an empty target database and restore:
```bash
createdb -h target-host -p 5433 -U restore_user toast_lab_restore
pg_restore -h target-host -p 5433 -U restore_user \
  -d toast_lab_restore --verbose toast_lab.dump
```
For schema-only or data-only work, add the appropriate `pg_dump`/`pg_restore` options and rehearse dependencies. `--clean`/`--create` can drop/recreate objects; use only after reviewing the exact effect.

## 3. Validate payload integrity
```sql
SELECT count(*) AS rows,
       sum(length(body)) AS body_chars,
       sum(octet_length(payload)) AS payload_bytes,
       sum(length(metadata::text)) AS metadata_chars
FROM demo.documents;
SELECT document_id, title, length(body), octet_length(payload),
       md5(body), md5(payload::text)
FROM demo.documents ORDER BY document_id;
```
`md5(bytea::text)` validates PostgreSQL's textual representation, not a canonical binary digest across every client formatting choice. For stronger binary integrity, compare `digest(payload,'sha256')` using `pgcrypto` on both ends or export a stable checksum manifest. For `text`, compare `md5(body)` or a stronger digest if required. Run same queries on source and restored target and compare results.

## 4. Large values and performance
- TOAST storage is transparent to `pg_dump`; it does not require dumping internal TOAST tables separately.
- Large values increase dump size, restore time, temporary disk, and network use. Monitor filesystem headroom and I/O.
- `pg_dump -j` parallelism is supported for directory format (`-Fd`) and can improve throughput; test disk and I/O contention.
- `pg_restore -j` can parallelize eligible objects when archive format supports it. Dependencies and large single-table data loads may limit scaling.
- Compression defaults/options vary by PostgreSQL version; consult `pg_dump --help`.
- Use consistent source snapshot semantics: `pg_dump` creates a transactionally consistent snapshot for a single database, but it does not capture cluster-global roles/tablespaces. Use `pg_dumpall --globals-only` separately when required.

## 5. Failure handling
- **Archive truncated:** verify command exit code, filesystem space, and archive listing; rerun dump to a new file.
- **Permission errors:** ensure backup role can read all required tables/sequences and large-object data if applicable.
- **Restore slow:** use verbose logs, parallel directory/custom-format restore where appropriate, and check target I/O; avoid increasing jobs without resource measurement.
- **Data mismatch:** stop cutover, compare row counts/checksum manifest, verify triggers/defaults and restore errors.
- **Unsupported extension/type:** install compatible extension packages and create extension prerequisites before restore.

## 6. Pass criteria
Dump exits 0, archive listing succeeds, restore exits 0, row counts and large-value checksums match, and application can read/write restored objects.
