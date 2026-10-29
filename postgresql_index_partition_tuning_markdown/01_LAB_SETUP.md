# 01 — Lab Setup: `postgres_air` + `demo.big_table1`

This section prepares the two data sets used by the live demo:

- **`postgres_air`**: realistic relational data for join, aggregation, rewrite and index examples.
- **`demo.big_table1`**: synthetic 5-million-row table for B-tree, range-selectivity, planner and parameter experiments.

> Run this in a disposable lab or a dedicated training database. Creating `demo.big_table1` requires disk space for five million rows, a large text payload, and the index. Allow time for table creation, index build and `ANALYZE`.

## 1. Download the `postgres_air` demo database

A public repository maintained for the `postgres_air` training database documents downloadable dump editions and restore instructions:

- Repository and README: <https://github.com/hettie-d/postgres_air>
- The README links to a shared download directory containing the 2024 edition (PostgreSQL 17), the 2023 edition (PostgreSQL 15), and the initial edition (PostgreSQL 13).
- Dump sizes are substantial (around 1.2–1.4 GB, depending on edition); ensure sufficient disk space before downloading.
- For closest reproduction of the book's query plans, use the PostgreSQL version associated with the dump edition. The data can be restored to other versions, but execution plans may differ.

Download the **custom-format** dump or the **plain SQL compressed** dump from the shared directory linked by the repository README. Do not assume a direct dump filename: select the desired edition and format in the current download directory.

## 2. Create a dedicated database and restore the dump

### Option A — custom-format dump (`pg_restore`)

Create a fresh database. Replace `<dump-file>` with the downloaded custom-format dump filename.

```bash
createdb -U postgres postgres_air_lab
pg_restore -U postgres -d postgres_air_lab --no-owner --verbose <dump-file>
```

If the archive contains the schema and data as expected, this restores the `postgres_air` schema into `postgres_air_lab`. `--no-owner` avoids attempting to restore original ownership. Add `--exit-on-error` if you want the restore to stop at the first error:

```bash
pg_restore -U postgres -d postgres_air_lab --no-owner --exit-on-error --verbose <dump-file>
```

### Option B — compressed plain-SQL dump

If you downloaded a ZIP containing a `.sql` file, extract it first, then load it into the fresh database:

```bash
createdb -U postgres postgres_air_lab
psql -U postgres -d postgres_air_lab -v ON_ERROR_STOP=1 -f postgres_air.sql
```

Use the actual extracted SQL filename. If the download directory offers a gzip-compressed SQL file instead, use `gunzip -c <dump.sql.gz> | psql -U postgres -d postgres_air_lab -v ON_ERROR_STOP=1`.

**Do not restore into a database containing valuable data.** Follow the selected dump's own instructions, and inspect the contents/format before restoring.

## 3. Verify `postgres_air`

Connect:

```bash
psql -U postgres -d postgres_air_lab
```

Then:

```sql
SELECT current_database(), version();

SELECT to_regclass('postgres_air.booking')       AS booking,
       to_regclass('postgres_air.booking_leg')   AS booking_leg,
       to_regclass('postgres_air.flight')        AS flight,
       to_regclass('postgres_air.passenger')     AS passenger,
       to_regclass('postgres_air.boarding_pass') AS boarding_pass;

SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname = 'postgres_air'
ORDER BY tablename;

ANALYZE;
```

If the `to_regclass` checks return `NULL`, stop and resolve the restore/schema issue before running the `postgres_air` examples.

## 4. Create the synthetic `demo.big_table1` table

Run this while connected to the same lab database. The table is independent of `postgres_air`; it exists to give the planner experiments a large, repeatable synthetic relation.

```sql
CREATE SCHEMA IF NOT EXISTS demo;

CREATE TABLE demo.big_table1 AS
SELECT
    i,
    (random()*1000000)::int AS val,
    repeat(md5(i::text),20) AS payload
FROM generate_series(1,5000000) i;

CREATE INDEX demo.idx_big_table_val1
ON demo.big_table1(val);

ANALYZE demo.big_table1;
```

### What this creates

- `i`: sequence from 1 through 5,000,000.
- `val`: random integer in the approximate range 0–1,000,000; repeated values are expected.
- `payload`: repeated MD5 text, providing a wider row so heap access and I/O are more noticeable.
- `demo.idx_big_table_val1`: B-tree index on `val`.

The SQL above uses the exact table/index names for this lab. In older notes, the index was named `idx_big_table1_val`; keep the names consistent with the SQL you actually ran.

### Verify the table, row count, index and size

```sql
SELECT count(*) AS rows FROM demo.big_table1;

SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'demo'
  AND tablename = 'big_table1';

SELECT pg_size_pretty(pg_relation_size('demo.big_table1')) AS heap_size,
       pg_size_pretty(pg_indexes_size('demo.big_table1')) AS indexes_size,
       pg_size_pretty(pg_total_relation_size('demo.big_table1')) AS total_size;
```

### First baseline query

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT *
FROM demo.big_table1
WHERE val BETWEEN 100000 AND 150000;
```

Do not expect the index to win automatically. This range may match a meaningful fraction of the table; PostgreSQL can legitimately prefer a sequential scan if fetching many wide rows through the index is estimated to cost more. The purpose is to observe the plan and compare under controlled changes.

## 5. Lab safety and repeatability

- Keep `postgres_air` and `demo.big_table1` in a dedicated training database.
- Record PostgreSQL version, data dump edition, table/index sizes and current settings.
- Run `ANALYZE demo.big_table1` after loading or materially changing the table.
- Capture the same query with the same predicates before and after each change.
- Use `RESET ALL;` only when you intend to clear all session-level settings.
- Do not manually delete rows from PostgreSQL system catalogs in a normal lab or production environment.
