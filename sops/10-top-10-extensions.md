# SOP 10 — Ten useful PostgreSQL extensions: install, create, use and validate

## Operating rules
An extension generally has two separate steps: install its OS/package files for the exact PostgreSQL major, then execute `CREATE EXTENSION` in each database that needs it. Availability, version, package name and support differ by distribution/managed service. Run `SELECT name, default_version, installed_version FROM pg_available_extensions ORDER BY name;` to discover what is installed locally. On managed services, use the provider's allowlist and parameter groups.

## 1. `pg_stat_statements` — query workload statistics
**Purpose:** aggregated statement execution and planning statistics.
- Install package if separated by distribution; configure `shared_preload_libraries = 'pg_stat_statements'` (merge with existing values, do not overwrite other entries), restart, then:
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT queryid, calls, round(total_exec_time::numeric,2) AS total_ms,
       rows, left(query,120) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;
```
Column names vary across versions; inspect view definition/docs. Reset statistics only with an approved diagnostic plan.

## 2. `pgcrypto` — cryptographic functions
```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT encode(digest('sample payload','sha256'),'hex');
SELECT gen_random_uuid();
```
Use application-level key management for secrets; do not treat a database hash as a password-storage scheme without a reviewed password-hashing design. Some functions have moved/changed across versions; check target docs.

## 3. `pg_trgm` — trigram similarity and text search
```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX customer_name_trgm_idx
  ON customer USING gin (full_name gin_trgm_ops);
SELECT full_name, similarity(full_name,'Jon Smyth') AS score
FROM customer WHERE full_name % 'Jon Smyth'
ORDER BY score DESC LIMIT 10;
```
Test index selectivity and write overhead; trigram indexes can be large.

## 4. `btree_gin` — B-tree-like operators in GIN
```sql
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE INDEX event_mix_gin_idx ON event_log
USING gin (tenant_id, event_type);
```
Use when combining supported scalar equality with GIN-indexed values is beneficial. It is not a universal replacement for B-tree indexes; benchmark query plans.

## 5. `btree_gist` — GiST support for scalar types/exclusion constraints
```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE room_booking (
  room_id integer NOT NULL,
  during tstzrange NOT NULL,
  EXCLUDE USING gist (room_id WITH =, during WITH &&)
);
```
This prevents overlapping bookings for the same room. Validate range bounds and transaction behavior.

## 6. `hstore` — key/value text map
```sql
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE TABLE app_settings(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, attrs hstore);
INSERT INTO app_settings(attrs) VALUES ('theme=>dark,region=>ap-south-1');
SELECT attrs -> 'theme' FROM app_settings;
```
For new designs, compare `jsonb` for nested structures, indexing and ecosystem compatibility before choosing `hstore`.

## 7. `uuid-ossp` — UUID generation functions
```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
SELECT uuid_generate_v4();
```
Quote the extension name because it contains a hyphen. PostgreSQL's built-in UUID generation capabilities vary by version; use the simplest supported function that meets requirements.

## 8. `postgres_fdw` — query a remote PostgreSQL server
```sql
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER remote_pg FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'remote.example', port '5432', dbname 'remotedb', sslmode 'verify-full');
CREATE USER MAPPING FOR CURRENT_USER SERVER remote_pg
  OPTIONS (user 'remote_reader', password 'set-through-approved-secret-process');
CREATE SCHEMA remote_data;
IMPORT FOREIGN SCHEMA public LIMIT TO (reference_table)
  FROM SERVER remote_pg INTO remote_data;
SELECT * FROM remote_data.reference_table LIMIT 10;
```
The literal password above is a placeholder only; do not execute as written. Prefer provider secret facilities, least-privilege remote roles and TLS. `postgres_fdw` does not make the remote database part of a local ACID boundary; inspect pushdown and transaction semantics.

## 9. `dblink` — execute SQL against another PostgreSQL database
```sql
CREATE EXTENSION IF NOT EXISTS dblink;
SELECT *
FROM dblink('host=remote.example dbname=remotedb user=readonly sslmode=verify-full',
            'SELECT current_database(), current_user')
AS r(dbname text, username text);
```
Connection strings need approved authentication; do not embed passwords in SQL logs. Prefer `postgres_fdw` for many structured federation use cases. Restrict who can call remote SQL.

## 10. `auto_explain` — log plans for slow statements
Configure `shared_preload_libraries` to include `auto_explain` (merge existing values), restart if required, then set controlled logging parameters:
```sql
LOAD 'auto_explain';
SET auto_explain.log_min_duration = '1s';
SET auto_explain.log_analyze = on;
SET auto_explain.log_buffers = on;
SET auto_explain.log_timing = off;
```
Settings and load behavior are version/configuration-dependent. `log_analyze` adds overhead, especially with timing; enable selectively and follow privacy/log-retention rules. Review server logs for plan output.

## Installation workflow
1. Record `SELECT version();` and `SHOW data_directory;`.
2. Confirm extension availability:
```sql
SELECT name, default_version, installed_version, comment
FROM pg_available_extensions
WHERE name IN ('pg_stat_statements','pgcrypto','pg_trgm','btree_gin',
 'btree_gist','hstore','uuid-ossp','postgres_fdw','dblink','auto_explain')
ORDER BY name;
```
3. Install matching OS package if missing. Package naming is distribution-specific.
4. Set preload parameters only where documented; preserve existing comma-separated values and schedule restart.
5. Execute `CREATE EXTENSION` in each required database (not every extension needs a SQL-level extension object; `auto_explain` is commonly loaded/configured rather than created).
6. Test least-privilege access, backup/restore, monitoring and upgrade compatibility.
7. Record extension version and target-major package:
```sql
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

## Major-upgrade checklist
- Install target-major extension binaries and dependencies before `pg_upgrade --check`.
- Read each extension's release notes and supported upgrade path.
- Run `ALTER EXTENSION ... UPDATE` only when required and supported.
- Test custom types, opclasses, operators, indexes, preload libraries and background workers.
- Confirm the managed service supports each extension before using it there.

## Security/performance cautions
- Extensions execute privileged server-side code; approve source, maintainer, package provenance and update policy.
- Use least privilege for FDW/dblink and avoid secrets in SQL history.
- Benchmark index extensions; extra indexes increase storage and write costs.
- Keep extension versions and OS packages aligned with the PostgreSQL major version.
