# PostgreSQL Indexing, Partitioning & Performance Tuning — Live Demo Runbook

> Lab setup is documented separately in [`01_LAB_SETUP.md`](01_LAB_SETUP.md). Start there to download/restore `postgres_air` and create `demo.big_table1`.
>
> Partitioning setup and runnable SQL are in [`01_LAB_SETUP.md`](01_LAB_SETUP.md), section 6.

## Visual workflow

```mermaid
flowchart LR
    A[Baseline query] --> B[EXPLAIN ANALYZE + BUFFERS]
    B --> C[One change]
    C --> D[Same query again]
    D --> E[Compare plan and I/O]
    E --> F[Keep, revert, or test next hypothesis]
```

---

**Copy/paste companion for the PostgreSQL Index & Tuning Lab app**

This runbook follows the app’s teaching sequence: establish a baseline with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`, make one change (usually an index), rerun the same query, and explain what changed. It then covers query rewrites, partitioning, and planner/executor settings. SQL is derived from the uploaded app’s `catalog.py`, setup SQL, and reference notes; example values are the app defaults.

## 0. Before the live demo
Run these in the database that contains `postgres_air`. The synthetic demo tables live in schema `demo`; partition scratch tables live in `lab_part`; the sorted BRIN copy lives in `labx`. The app’s Reset removes `*_lab_idx` indexes and scratch schemas, so do not use it if you want to retain your own lab indexes.
```sql
-- Confirm database/version and schema availability
SELECT current_database(), version();
SELECT to_regclass('postgres_air.booking') AS booking,
       to_regclass('postgres_air.flight') AS flight,
       to_regclass('demo.employees') AS employees;

-- Synthetic data setup (run from shell/psql if demo schema is not populated):
-- psql -d <database> -f sql/setup_demo.sql
-- Smaller load: psql -d <database> -v docs=100000 -v places=600000 -v users=1500000 -v logs=2000000 -v emps=1500000 -f sql/setup_demo.sql

-- big_table1 is optional for planner demos. This creates 5M rows in demo.big_table1.
-- Run only if you do not already have a suitable big_table1.
-- psql -d <database> -f sql/setup_bigtable.sql
```

**Measurement rule:** keep the query text and parameters the same, run `ANALYZE` after creating an index, compare plan node type, actual rows, buffers, heap blocks, temp blocks, sort method, hash batches, and execution time. Timing varies with cache state and server load; do not present a single run as a universal benchmark.

## 1. Index labs: baseline → index → rerun
For each lab, the baseline should be captured before creating the target index. The app’s index actions create the listed DDL and run `ANALYZE`; copy/paste equivalent steps below. When comparing alternative indexes, drop the competing lab index so PostgreSQL cannot choose the other one.

### 1.btree — B-Tree
Equality, range and ORDER BY. The default index, and the one to prefer unless the workload needs another type.
- Prefer B-tree unless the workload requires otherwise (Quick Reference, best practices).
- Foreign-key columns are not indexed automatically: deleting a parent row, or joining from it, scans the whole child table.

#### Real data: boarding_pass FK lookup (postgres_air)
Requires: postgres_air.boarding_pass.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS postgres_air.boarding_pass_bl_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT pass_id, passenger_id, seat FROM postgres_air.boarding_pass WHERE booking_leg_id = 50000
```

**Step C — create and test: B-tree on (booking_leg_id).**
```sql
CREATE INDEX boarding_pass_bl_lab_idx ON postgres_air.boarding_pass (booking_leg_id);
ANALYZE postgres_air.boarding_pass;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT pass_id, passenger_id, seat FROM postgres_air.boarding_pass WHERE booking_leg_id = 50000
```

**App note:** boarding_pass.booking_leg_id is a foreign key with no index. Your recorded run: ~7.2 s → 0.015 ms.

#### Synthetic: employees by e-mail (equality)
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_email_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, salary FROM demo.employees WHERE email = 'arjun.sharma2000000@Example.com'
```

**Step C — create and test: B-tree on (email).**
```sql
CREATE INDEX employees_email_lab_idx ON demo.employees (email);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, salary FROM demo.employees WHERE email = 'arjun.sharma2000000@Example.com'
```


### 1.multicol — Multi-column
One composite index can satisfy two predicates (and, here, the aggregate) at once.
- Create the single-column index first, run, drop it, then create the composite and run again.
- With only (department_id) the index finds ~1/50 of the table and salary is filtered afterwards (see 'Rows Removed by Filter').
- PostgreSQL 18 adds B-tree skip scan, so a composite index can also help when the leading column is not constrained.
- Column order matters: equality columns first, range columns last.

#### employees: department_id = 10 AND salary > N
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_dept_lab_idx;
DROP INDEX IF EXISTS demo.employees_dept_sal_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) AS n, round(avg(salary), 2) AS avg_salary FROM demo.employees WHERE department_id = 10 AND salary > 190000
```

**Step C — create and test: B-tree on (department_id).**
```sql
CREATE INDEX employees_dept_lab_idx ON demo.employees (department_id);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) AS n, round(avg(salary), 2) AS avg_salary FROM demo.employees WHERE department_id = 10 AND salary > 190000
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS demo.employees_dept_lab_idx;
```

**Step D — create and test: B-tree on (department_id, salary).**
```sql
CREATE INDEX employees_dept_sal_lab_idx ON demo.employees (department_id, salary);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) AS n, round(avg(salary), 2) AS avg_salary FROM demo.employees WHERE department_id = 10 AND salary > 190000
```


### 1.covering — Covering (INCLUDE)
INCLUDE columns let a projection query be answered from the index alone (Index Only Scan).
- Heap access is avoided only when the visibility map allows it: watch 'Heap Fetches' in the plan (setup runs VACUUM so pages are all-visible).
- Your PDF's chapter 05 is the cautionary tale: with 30 rows on one page the covering index was 2.25× bigger and no faster. Compare the index sizes shown here.
- Covering indexes cannot use B-tree deduplication, so they grow faster than plain ones.

#### SELECT employee_name, salary WHERE department_id = 10
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_dept_lab_idx;
DROP INDEX IF EXISTS demo.employees_dept_cover_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
For an index-only scan demonstration, vacuum/analyze first so visibility-map coverage is high:
```sql
VACUUM (ANALYZE) demo.employees;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT employee_name, salary FROM demo.employees WHERE department_id = 10
```

**Step C — create and test: B-tree on (department_id).**
```sql
CREATE INDEX employees_dept_lab_idx ON demo.employees (department_id);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT employee_name, salary FROM demo.employees WHERE department_id = 10
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS demo.employees_dept_lab_idx;
```

**Step D — create and test: B-tree on (department_id) INCLUDE (employee_name, salary).**
```sql
CREATE INDEX employees_dept_cover_lab_idx ON demo.employees (department_id) INCLUDE (employee_name, salary);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT employee_name, salary FROM demo.employees WHERE department_id = 10
```


### 1.functional — Functional (expression)
Index the expression itself so a function in WHERE becomes indexable, and pick the right operator class for LIKE.
- The predicate must match the expression exactly: lower(email) is not served by an index on upper(email), and ILIKE does not use it either.
- LIKE 'abc%' needs text_pattern_ops unless the database collation is C. Check the collation shown in Environment: with en_IN (or any non-C collation) the default operator class cannot serve a prefix search.
- A text_pattern_ops index does not serve <, > or ORDER BY in collation order.

#### lower(email) = 'x' (equality)
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_lower_email_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE lower(email) = 'arjun.sharma2000000@example.com'
```

**Step C — create and test: B-tree on (lower(email)).**
```sql
CREATE INDEX employees_lower_email_lab_idx ON demo.employees (lower(email));
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE lower(email) = 'arjun.sharma2000000@example.com'
```


#### lower(email) LIKE 'prefix%' (operator class)
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_lower_email_lab_idx;
DROP INDEX IF EXISTS demo.employees_lower_email_pat_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) AS n FROM demo.employees WHERE lower(email) LIKE 'john.smith12%'
```

**Step C — create and test: default operator class.**
```sql
CREATE INDEX employees_lower_email_lab_idx ON demo.employees (lower(email));
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) AS n FROM demo.employees WHERE lower(email) LIKE 'john.smith12%'
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS demo.employees_lower_email_lab_idx;
```

**Step D — create and test: text_pattern_ops.**
```sql
CREATE INDEX employees_lower_email_pat_lab_idx ON demo.employees (lower(email) text_pattern_ops);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) AS n FROM demo.employees WHERE lower(email) LIKE 'john.smith12%'
```

**App note:** Create the default one first and run: on a non-C collation it stays a Seq Scan. Then create text_pattern_ops.

### 1.partial — Partial
Index only the rows a hot query cares about: far smaller, and updates to other rows never touch it.
- Good for a rare, stable value that every query names, e.g. a dashboard polling the latest canceled flights.
- Not for a value that changes per query, and the query predicate must imply the index predicate.
- If both indexes exist the planner may keep using the full one: drop it before judging the partial one (your PDF, chapter 06).

#### Real data: latest 20 canceled flights (postgres_air)
Requires: postgres_air.flight.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS postgres_air.flight_status_lab_idx;
DROP INDEX IF EXISTS postgres_air.flight_rare_status_dep_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT flight_id, flight_no, scheduled_departure FROM postgres_air.flight WHERE status = 'Canceled' ORDER BY scheduled_departure DESC LIMIT 20
```

**Step C — create and test: full B-tree on (status).**
```sql
CREATE INDEX flight_status_lab_idx ON postgres_air.flight (status);
ANALYZE postgres_air.flight;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT flight_id, flight_no, scheduled_departure FROM postgres_air.flight WHERE status = 'Canceled' ORDER BY scheduled_departure DESC LIMIT 20
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS postgres_air.flight_status_lab_idx;
```

**Step D — create and test: partial B-tree on (scheduled_departure) WHERE status = 'Canceled'.**
```sql
CREATE INDEX flight_rare_status_dep_lab_idx ON postgres_air.flight (scheduled_departure) WHERE status = 'Canceled';
ANALYZE postgres_air.flight;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT flight_id, flight_no, scheduled_departure FROM postgres_air.flight WHERE status = 'Canceled' ORDER BY scheduled_departure DESC LIMIT 20
```

**App note:** Your recorded run: no index 48 ms, full index 0.16 ms (59 buffers), partial 0.017 ms (15 buffers), 16 kB vs 4.7 MB.

### 1.gin — GIN
Inverted index for values that contain many keys: arrays, JSONB, full-text.
- GIN is built for 'contains' operators (@>, @@). Builds are slower and indexes bigger than B-tree.
- Selectivity decides the win: a term that matches most rows makes the planner (rightly) choose a sequential scan.

#### Full-text search (original demo, tsvector expression)
Requires: demo.documents.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.documents_body_gin_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, title, left(body, 160) AS snippet, ts_rank(to_tsvector('english', body), q) AS rank FROM demo.documents, plainto_tsquery('english', 'patroni failover') AS q WHERE to_tsvector('english', body) @@ q ORDER BY rank DESC LIMIT 20
```

**Step C — create and test: GIN on to_tsvector('english', body).**
```sql
CREATE INDEX documents_body_gin_lab_idx ON demo.documents USING gin (to_tsvector('english', body));
ANALYZE demo.documents;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, title, left(body, 160) AS snippet, ts_rank(to_tsvector('english', body), q) AS rank FROM demo.documents, plainto_tsquery('english', 'patroni failover') AS q WHERE to_tsvector('english', body) @@ q ORDER BY rank DESC LIMIT 20
```

**App note:** No stored tsvector column: without the index to_tsvector() is computed for every row.

#### Array containment: skills @> ARRAY[…]
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_skills_gin_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE skills @> '{PostgreSQL,Patroni}'::text[]
```

**Step C — create and test: GIN on (skills).**
```sql
CREATE INDEX employees_skills_gin_lab_idx ON demo.employees USING gin (skills);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE skills @> '{PostgreSQL,Patroni}'::text[]
```


#### JSONB containment: profile @> '{…}'
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_profile_gin_lab_idx;
DROP INDEX IF EXISTS demo.employees_profile_gpo_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE profile @> '{"city":"Delhi"}'::jsonb
```

**Step C — create and test: GIN on (profile)  [jsonb_ops].**
```sql
CREATE INDEX employees_profile_gin_lab_idx ON demo.employees USING gin (profile);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE profile @> '{"city":"Delhi"}'::jsonb
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS demo.employees_profile_gin_lab_idx;
```

**Step D — create and test: GIN on (profile jsonb_path_ops)  [smaller, containment only].**
```sql
CREATE INDEX employees_profile_gpo_lab_idx ON demo.employees USING gin (profile jsonb_path_ops);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE profile @> '{"city":"Delhi"}'::jsonb
```


### 1.trgm — pg_trgm
Trigram GIN index for LIKE / ILIKE with leading wildcards and fuzzy search.
- A B-tree cannot serve '%john%'. pg_trgm splits strings into trigrams and indexes those.
- ANALYZE after creating the index (the app does it for you).
- Very short patterns (under 3 characters) give the index nothing to work with.

#### employee_name ILIKE '%john%'
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_name_trgm_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE employee_name ILIKE '%sharma 12345%'
```

**Step C — create and test: GIN on (employee_name gin_trgm_ops).**
```sql
CREATE INDEX employees_name_trgm_lab_idx ON demo.employees USING gin (employee_name gin_trgm_ops);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name FROM demo.employees WHERE employee_name ILIKE '%sharma 12345%'
```


### 1.gist — GiST
Balanced, general-purpose tree for geometry and anything with 'nearness': containment, overlap, nearest-neighbour.
- GiST also supports ORDER BY distance (<->) with LIMIT: a true nearest-neighbour search without sorting.
- General purpose; this is what PostGIS builds on. Compare with SP-GiST for sparse point data.

#### Nearest restaurants (KNN on the sphere, original demo)
Requires: demo.restaurants.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.restaurants_earth_gist_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, name, round((earth_distance(ll_to_earth(lat, lon), ll_to_earth(12.97, 77.59)) / 1000)::numeric, 2) AS km FROM demo.restaurants ORDER BY ll_to_earth(lat, lon) <-> ll_to_earth(12.97, 77.59) LIMIT 10
```

**Step C — create and test: GiST on (ll_to_earth(lat, lon)).**
```sql
CREATE INDEX restaurants_earth_gist_lab_idx ON demo.restaurants USING gist (ll_to_earth(lat, lon));
ANALYZE demo.restaurants;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, name, round((earth_distance(ll_to_earth(lat, lon), ll_to_earth(12.97, 77.59)) / 1000)::numeric, 2) AS km FROM demo.restaurants ORDER BY ll_to_earth(lat, lon) <-> ll_to_earth(12.97, 77.59) LIMIT 10
```

**App note:** Great-circle distance costs ~3 µs per row, which is why this takes seconds without the index.

#### Points in a box: office_location <@ box(…)  (Quick Reference example)
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_loc_gist_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, office_location FROM demo.employees WHERE office_location <@ box(point(10, 10), point(11, 11))
```

**Step C — create and test: GiST on (office_location).**
```sql
CREATE INDEX employees_loc_gist_lab_idx ON demo.employees USING gist (office_location);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, office_location FROM demo.employees WHERE office_location <@ box(point(10, 10), point(11, 11))
```


### 1.spgist — SP-GiST
Space-partitioned trees (tries, quad-trees): sparse or clustered data, prefix search.
- GiST vs SP-GiST: balanced tree, general purpose (PostGIS) vs space partitioned, for sparse data, points, IP addresses, text tries.
- Run the box query with GiST, drop it, create SP-GiST, and compare. If both exist the planner picks one.
- The prefix operator ^@ (starts with) is what SP-GiST text_ops supports natively.

#### E-mail prefix autocomplete (normalised key, original demo)
Requires: demo.users.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.users_norm_email_spgist_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT email FROM demo.users WHERE demo.norm_email(email) ^@ 'arjun7f' ORDER BY email LIMIT 20
```

**Step C — create and test: SP-GiST on (norm_email(email)).**
```sql
CREATE INDEX users_norm_email_spgist_lab_idx ON demo.users USING spgist (demo.norm_email(email));
ANALYZE demo.users;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT email FROM demo.users WHERE demo.norm_email(email) ^@ 'arjun7f' ORDER BY email LIMIT 20
```


#### Points in a box: office_location <@ box(…)  (Quick Reference example)
Requires: demo.employees.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.employees_loc_spgist_lab_idx;
DROP INDEX IF EXISTS demo.employees_loc_gist_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, office_location FROM demo.employees WHERE office_location <@ box(point(10, 10), point(11, 11))
```

**Step C — create and test: SP-GiST on (office_location).**
```sql
CREATE INDEX employees_loc_spgist_lab_idx ON demo.employees USING spgist (office_location);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, office_location FROM demo.employees WHERE office_location <@ box(point(10, 10), point(11, 11))
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS demo.employees_loc_spgist_lab_idx;
```

**Step D — create and test: GiST on (office_location).**
```sql
CREATE INDEX employees_loc_gist_lab_idx ON demo.employees USING gist (office_location);
ANALYZE demo.employees;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT emp_id, employee_name, office_location FROM demo.employees WHERE office_location <@ box(point(10, 10), point(11, 11))
```


### 1.brin — BRIN
Block-range summaries: a tiny index for huge, naturally ordered (append-only) tables.
- Use BRIN only on huge, append-only tables whose physical order follows the column (logs, events).
- B-tree vs BRIN: precise lookup, larger index, random access, OLTP vs block summaries, tiny index, append-only, data warehouse.
- BRIN is only as good as pg_stats.correlation: on your flight table (0.45) it was slower than no index for a month filter.

#### Recent error logs (original demo)
Requires: demo.logs.
**Step A — clean baseline (only run the DROP statements for indexes you are happy to remove).**
```sql
DROP INDEX IF EXISTS demo.logs_event_time_brin_lab_idx;
DROP INDEX IF EXISTS demo.logs_event_time_btree_lab_idx;
```

**Step B — baseline plan, before creating the target index.**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, event_time, message FROM demo.logs WHERE event_time > ''::timestamptz - make_interval(mins => 5) AND message ~* 'error.*(timeout|refused)' ORDER BY event_time DESC LIMIT 100
```

**Step C — create and test: BRIN on (event_time), pages_per_range = 32.**
```sql
CREATE INDEX logs_event_time_brin_lab_idx ON demo.logs USING brin (event_time) WITH (pages_per_range = 32);
ANALYZE demo.logs;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, event_time, message FROM demo.logs WHERE event_time > ''::timestamptz - make_interval(mins => 5) AND message ~* 'error.*(timeout|refused)' ORDER BY event_time DESC LIMIT 100
```

Before testing the next alternative, drop this index (and any competing index) so the comparison is isolated:
```sql
DROP INDEX IF EXISTS demo.logs_event_time_brin_lab_idx;
```

**Step D — create and test: B-tree on (event_time)  [for the size comparison].**
```sql
CREATE INDEX logs_event_time_btree_lab_idx ON demo.logs (event_time);
ANALYZE demo.logs;
```

Rerun the exact same query:
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id, event_time, message FROM demo.logs WHERE event_time > ''::timestamptz - make_interval(mins => 5) AND message ~* 'error.*(timeout|refused)' ORDER BY event_time DESC LIMIT 100
```


#### Real data: correlation decides — flight (postgres_air)
Requires: postgres_air.flight.

**Variant — A day / no index**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-11'::timestamptz AND scheduled_departure < '2024-08-12'::timestamptz
```


**Variant — A month / no index**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```


**Variant — B day / btree**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-11'::timestamptz AND scheduled_departure < '2024-08-12'::timestamptz
```


**Variant — B month / btree**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```

```sql
DROP INDEX IF EXISTS postgres_air.flight_sd_btree_lab_idx
```


**Variant — C day / brin (as loaded)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-11'::timestamptz AND scheduled_departure < '2024-08-12'::timestamptz
```


**Variant — C month / brin (as loaded)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```

```sql
DROP INDEX IF EXISTS postgres_air.flight_sd_brin_lab_idx
```


**Variant — D day / brin on sorted copy**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM labx.flight_sorted WHERE scheduled_departure >= '2024-08-11'::timestamptz AND scheduled_departure < '2024-08-12'::timestamptz
```


**Variant — D month / brin on sorted copy**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM labx.flight_sorted WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```


### 1.hypopg — HypoPG
Hypothetical indexes: see what the planner would do with an index, without building it.
- Test with HypoPG before building expensive indexes (Quick Reference, best practices).
- Only plain EXPLAIN works with hypothetical indexes: EXPLAIN ANALYZE ignores them, so no query is executed here.
- Requires the hypopg extension (CREATE EXTENSION hypopg). If it is not installed the page shows the SQL to try.

#### employees: would (department_id, salary) help?
Requires: demo.employees.
**Hypothetical index lab** — this intentionally uses plain `EXPLAIN`, not `EXPLAIN ANALYZE`; HypoPG indexes are hypothetical and do not execute the query.
Baseline:
```sql
EXPLAIN SELECT count(*) AS n FROM demo.employees WHERE department_id = 10 AND salary > 190000
```

If HypoPG is installed:
```sql
CREATE EXTENSION IF NOT EXISTS hypopg;
SELECT * FROM hypopg_create_index('CREATE INDEX ON demo.employees (department_id, salary)');
EXPLAIN SELECT count(*) AS n FROM demo.employees WHERE department_id = 10 AND salary > 190000;
SELECT * FROM hypopg_reset();
```


## 2. Planner and parameter-tuning labs
These are not index-creation exercises. Keep the same query and change one setting at a time. Use `RESET` or `RESET ALL` after each comparison.

### 2.selectivity — Planner decision flow
How many rows come back decides the plan: very few → Index Scan, medium → Bitmap Heap Scan, large → Sequential Scan.
- Recorded in your notes: ~15 ms, ~4.9 s and ~7.0 s (5M-row table).
- Medium selectivity: lossy heap blocks and 'Rows Removed by Index Recheck' appear when the bitmap does not fit in work_mem.

#### big_table1: three ranges on val

**Very few rows (val 1–15)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 1 AND 15
```


**Medium (val 100000–150000)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000
```


**Large (val 100000–350000)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 350000
```


### 2.rpc — random_page_cost
Planner cost model. Lowering it can flip Bitmap Heap Scan to Index Scan: only good if it matches your storage.
- Default 4; SSD guidance is 1.1.
- Your notes: random_page_cost = 1.0 changed the medium-selectivity query from Bitmap Heap Scan (~4.9 s) to Index Scan (~19.8 s). Lowering it too aggressively can produce a slower plan.
- Planner-only setting: no restart, applies via SET LOCAL here.

#### Medium-selectivity query at different random_page_cost

**random_page_cost = 4 (default)**
```sql
SET random_page_cost = 4;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000
```

```sql
RESET ALL;
```


**random_page_cost = 1.1 (SSD guidance)**
```sql
SET random_page_cost = 1.1;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000
```

```sql
RESET ALL;
```


**random_page_cost = 1.0**
```sql
SET random_page_cost = 1.0;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000
```

```sql
RESET ALL;
```


### 2.eic — effective_io_concurrency
Executor setting: lets a Bitmap Heap Scan prefetch pages asynchronously. The plan stays identical; only the time changes.
- Primary beneficiary: Bitmap Heap Scan. Regular Index Scan: negligible direct benefit. Sequential Scan: none.
- Run with random_page_cost = 4 and the other scan types disabled so the plan is a Bitmap Heap Scan both times.
- How much it helps depends on the storage (cloud SSD vs local NVMe) and on the OS cache.

#### Bitmap Heap Scan with effective_io_concurrency 1 vs 200

**effective_io_concurrency = 1**
```sql
SET random_page_cost = 4;
SET enable_seqscan = off;
SET enable_indexscan = off;
SET effective_io_concurrency = 1;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000
```

```sql
RESET ALL;
```


**effective_io_concurrency = 200**
```sql
SET random_page_cost = 4;
SET enable_seqscan = off;
SET enable_indexscan = off;
SET effective_io_concurrency = 200;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000
```

```sql
RESET ALL;
```


### 2.parallel — Parallel query & aggregates
Gather, Partial Aggregate and Finalize Aggregate; why AVG() ships SUM and COUNT, not averages.
- Each participating process (leader + workers) produces one partial result; Finalize Aggregate combines them.
- Workers do NOT send averages: each keeps SUM and COUNT, and the final step computes SUM/COUNT. Averaging worker averages would be wrong.
- AVG needs a richer transition state than SUM, which is why Finalize Aggregate reports a larger width.
- On a 2 vCPU box more than 2 workers gains little: five processes take turns on two cores.

#### count(*) with 0 / 2 / 4 workers, then SUM and AVG

**count(*), max_parallel_workers_per_gather = 0**
```sql
SET max_parallel_workers_per_gather = 0;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM demo.big_table1
```

```sql
RESET ALL;
```


**count(*), 2 workers**
```sql
SET max_parallel_workers_per_gather = 2;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM demo.big_table1
```

```sql
RESET ALL;
```


**count(*), 4 workers**
```sql
SET max_parallel_workers_per_gather = 4;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM demo.big_table1
```

```sql
RESET ALL;
```


**SUM(val), 2 workers**
```sql
SET max_parallel_workers_per_gather = 2;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT sum(val) FROM demo.big_table1
```

```sql
RESET ALL;
```


**AVG(val), 2 workers**
```sql
SET max_parallel_workers_per_gather = 2;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT avg(val) FROM demo.big_table1
```

```sql
RESET ALL;
```


### 2.searches — Index Searches (PostgreSQL 18)
A range does one B-tree descent then walks the leaf pages; an IN list does an independent descent per constant.
- The 'Index Searches: N' EXPLAIN line is new in PostgreSQL 18; older versions do not print it.
- Range: one traversal, then the linked leaf pages. IN (a,b,c,d): four traversals.

#### Range vs IN list on idx_big_table1_val

**Range: val BETWEEN 1 AND 15**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 1 AND 15
```


**IN: val IN (10, 1000, 500000, 900000)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val IN (10, 1000, 500000, 900000)
```


### 2.restart — huge_pages, io_method & the parameter map
Settings that need a restart or OS changes: what is in force right now, and which parameter affects what.
- huge_pages and io_method need a server restart (the app cannot change them). Huge pages also need vm.nr_hugepages on Linux.
- PostgreSQL page = 8 KB, huge page = 2 MB → one huge page holds 256 PostgreSQL pages. SELECT * still reads 8 KB pages: huge pages only reduce TLB misses and page-table overhead.
- io_method = io_uring (PostgreSQL 18) → asynchronous Linux I/O; 'worker' is the default.

#### Live values
Inspect current values:
```sql
SELECT name, setting, unit, context, source
FROM pg_settings
WHERE name = ANY (ARRAY['random_page_cost','effective_io_concurrency','huge_pages','huge_pages_status','io_method','shared_buffers','work_mem','hash_mem_multiplier','maintenance_work_mem','effective_cache_size','max_worker_processes','max_parallel_workers','max_parallel_workers_per_gather','max_parallel_maintenance_workers','jit','default_statistics_target'])
ORDER BY name;
```


### 2.work_mem — memory versus temporary-file I/O
Use the same medium-selectivity range on `demo.big_table1`. The index should already exist from the setup script. Your recorded `postgres_air` aggregation example showed sort changing from external merge to quicksort and parallel hash joins from multiple batches to one after increasing `work_mem` to 128MB; your `big_table1` demo should be measured separately.
```sql
-- Baseline (use current/default work_mem)
RESET work_mem;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000;

-- Controlled test
SET work_mem = '256MB';
SET effective_io_concurrency = 1;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000;

SET effective_io_concurrency = 64;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM demo.big_table1 WHERE val BETWEEN 100000 AND 150000;

RESET ALL;
```

`work_mem` affects sorts, hash joins, hash aggregates, and bitmap memory; it is not a per-query total. Multiple plan nodes and parallel workers may each consume memory. `effective_io_concurrency` primarily affects asynchronous prefetch for bitmap heap scans on supported storage; it is not expected to accelerate a normal index scan or sequential scan directly.

## 3. Query rewrite labs (same results, different plan shapes)

### 3.pgbadger — CTE 'filter early' (pgbadger)
A slow query from pgbadger, and the 'apply the filter early' rewrite. Is it a real optimisation?
- Since PostgreSQL 12 a CTE referenced once is inlined, so 'filter early in a CTE' usually compiles to the same plan as filtering directly.
- Variant C adds AS MATERIALIZED (an optimisation fence) as a contrast: now the CTE really is evaluated first.
- Always prove equivalence before timing: a rewrite that returns different rows is not a rewrite.

**A  CTE 'filter early'**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
WITH filtered AS (
    SELECT booking_id
    FROM postgres_air.booking
    WHERE price < 100  -- Apply filter early
)
SELECT bl.flight_id,
       departure_airport,
       (avg(b.price))::numeric(7,2) AS avg_price,
       count(DISTINCT p.passenger_id) AS num_passengers
FROM filtered
JOIN postgres_air.booking b USING (booking_id)
JOIN postgres_air.booking_leg bl USING (booking_id)
JOIN postgres_air.flight f USING (flight_id)
JOIN postgres_air.passenger p USING (booking_id)
GROUP BY bl.flight_id, departure_airport
```


**B  filter in WHERE**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT bl.flight_id,
       departure_airport,
       (avg(b.price))::numeric(7,2) AS avg_price,
       count(DISTINCT p.passenger_id) AS num_passengers
FROM postgres_air.booking b
JOIN postgres_air.booking_leg bl USING (booking_id)
JOIN postgres_air.flight f USING (flight_id)
JOIN postgres_air.passenger p USING (booking_id)
WHERE b.price < 100  -- Apply filter here directly
GROUP BY bl.flight_id, departure_airport
```


**C  CTE AS MATERIALIZED (bonus)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
WITH filtered AS MATERIALIZED (
    SELECT booking_id
    FROM postgres_air.booking
    WHERE price < 100  -- Apply filter early
)
SELECT bl.flight_id,
       departure_airport,
       (avg(b.price))::numeric(7,2) AS avg_price,
       count(DISTINCT p.passenger_id) AS num_passengers
FROM filtered
JOIN postgres_air.booking b USING (booking_id)
JOIN postgres_air.booking_leg bl USING (booking_id)
JOIN postgres_air.flight f USING (flight_id)
JOIN postgres_air.passenger p USING (booking_id)
GROUP BY bl.flight_id, departure_airport
```


### 3.pushdown — Aggregation pushdown
Aggregate early, join late: count boarding passes per flight first (~254k rows) instead of carrying ~30M joined rows to the GROUP BY.
- Your recorded run: 81.5 s → 36.7 s (2.2×), temp written 3.7 GB → 1.9 GB, identical result (2,207 rows both ways).
- Safe here because flight_id and airport_code are primary keys: joining after aggregation cannot multiply rows. If a dimension join could multiply or drop rows, the rewrite would change the answer.
- Read the row counts: ~30 million rows enter the top aggregate in plan A and are sorted on disk.

**A original join-then-group**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT a.city, date_trunc('month', f.scheduled_departure) AS month, count(*) AS passengers FROM postgres_air.airport a JOIN postgres_air.flight f ON a.airport_code = f.departure_airport JOIN postgres_air.booking_leg l ON f.flight_id = l.flight_id JOIN postgres_air.boarding_pass b ON b.booking_leg_id = l.booking_leg_id GROUP BY 1, 2
```


**B aggregate-then-join**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT a.city, date_trunc('month', f.scheduled_departure) AS month, sum(cnt.passengers) AS passengers FROM postgres_air.airport a JOIN postgres_air.flight f ON a.airport_code = f.departure_airport JOIN (SELECT l.flight_id, count(*) AS passengers FROM postgres_air.booking_leg l JOIN postgres_air.boarding_pass b USING (booking_leg_id) GROUP BY l.flight_id) cnt USING (flight_id) GROUP BY 1, 2
```


### 3.semijoin — IN vs EXISTS, NOT IN vs NOT EXISTS
IN and EXISTS compile to the same semi-join. NOT IN is different: NULL semantics, and a plan that may never finish.
- IN and EXISTS: same plan, same time within noise. 'Rewrite IN as EXISTS' is not a tuning technique by itself.
- If the subquery returns even one NULL, NOT IN returns zero rows; NOT EXISTS ignores NULLs.
- NOT IN becomes an unhashed SubPlan over a Materialize when the values do not fit in work_mem × hash_mem_multiplier: it re-scans per outer row.
- NOT IN is run under a 30 s statement_timeout on purpose: expect 'canceling statement due to statement timeout'. Without it, it can run for hours.

**NULL semantics, on three values**
```sql
SELECT 3 NOT IN (1, 2) AS not_in_without_null, 3 NOT IN (1, 2, NULL) AS not_in_with_null
```


**NULLs in the real column (one NULL would make NOT IN return nothing)**
```sql
SELECT count(*) FILTER (WHERE booking_leg_id IS NULL) AS null_booking_leg_ids FROM postgres_air.boarding_pass
```


**A IN**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.booking_leg l WHERE l.booking_leg_id IN (SELECT b.booking_leg_id FROM postgres_air.boarding_pass b)
```


**B EXISTS**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.booking_leg l WHERE EXISTS (SELECT 1 FROM postgres_air.boarding_pass b WHERE b.booking_leg_id = l.booking_leg_id)
```


**C NOT EXISTS**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.booking_leg l WHERE NOT EXISTS (SELECT 1 FROM postgres_air.boarding_pass b WHERE b.booking_leg_id = l.booking_leg_id)
```


**D NOT IN (30 s timeout)**
```sql
SET statement_timeout = '30s';
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.booking_leg l WHERE l.booking_leg_id NOT IN (SELECT b.booking_leg_id FROM postgres_air.boarding_pass b)
```

```sql
RESET statement_timeout;
```


## 4. Partitioning labs
Partitioning is a table-layout and data-management strategy, not a replacement for indexing. First demonstrate routing and boundaries on small scratch tables, then pruning on the `postgres_air` copy, then partition indexes and partition-wise joins/aggregates. All scratch objects use `lab_part`; destructive cleanup commands are scoped to those lab tables.

### 4.list — LIST partitioning
Discrete values (region, department, tenant). DEFAULT partition, ATTACH/DETACH, and why ATTACH fails when DEFAULT already holds the value.
- A DEFAULT partition is a safety net; monitor it. A growing DEFAULT means future partitions are missing.
- Use a temporary CHECK constraint before ATTACH so PostgreSQL can skip the validation scan.
- Use tableoid::regclass whenever you need to know which partition actually stores a row.
- CREATE ... PARTITION OF makes a new partition; ATTACH PARTITION adopts an existing table (migrations, bulk loads).

#### EMP lab: routing, DEFAULT, ATTACH, DETACH
**Step 1: Clean up any earlier run**
```sql
DROP TABLE IF EXISTS lab_part.emp_list CASCADE; DROP TABLE IF EXISTS lab_part.emp_list_2; DROP TABLE IF EXISTS lab_part.emp_list_4
```

**Step 2: Parent table, partitioned by LIST (a virtual table: it stores no rows)**
```sql
CREATE SCHEMA IF NOT EXISTS lab_part; CREATE TABLE lab_part.emp_list (id int, sal int) PARTITION BY LIST (id)
```

**Step 3: Three partitions, each owning discrete values**
```sql
CREATE TABLE lab_part.emp_list_1 PARTITION OF lab_part.emp_list FOR VALUES IN (1,4,6); CREATE TABLE lab_part.emp_list_2 PARTITION OF lab_part.emp_list FOR VALUES IN (2,3,5); CREATE TABLE lab_part.emp_list_3 PARTITION OF lab_part.emp_list FOR VALUES IN (8,9)
```

**Step 4: Insert into the parent**
```sql
INSERT INTO lab_part.emp_list VALUES (1,1000),(2,2000),(3,3000),(4,4000),(5,5000),(6,6000),(8,8000),(9,9000)
```

**Step 5: Verify routing with tableoid::regclass**
```sql
SELECT tableoid::regclass AS partition_name, * FROM lab_part.emp_list ORDER BY id
```

**Step 6: Without a DEFAULT partition an unknown value is rejected**
```sql
INSERT INTO lab_part.emp_list VALUES (7, 7000)
```

Expected demonstration error: ERROR: no partition of relation "emp_list" found for row
**Step 7: Create the DEFAULT partition, then insert 7 again**
```sql
CREATE TABLE lab_part.emp_list_default PARTITION OF lab_part.emp_list DEFAULT; INSERT INTO lab_part.emp_list VALUES (7, 7000)
```

**Step 8: Where did 7 go?**
```sql
SELECT tableoid::regclass AS partition_name, * FROM lab_part.emp_list WHERE id = 7
```

**Step 9: ATTACH a partition for 7 while the DEFAULT still holds a row for 7**
```sql
CREATE TABLE lab_part.emp_list_4 (LIKE lab_part.emp_list INCLUDING ALL); ALTER TABLE lab_part.emp_list ATTACH PARTITION lab_part.emp_list_4 FOR VALUES IN (7)
```

Expected demonstration error: ERROR: updated partition constraint for default partition would be violated by some row
**Step 10: Correct workflow, step 1: matching CHECK constraint (lets ATTACH skip the validation scan)**
```sql
ALTER TABLE lab_part.emp_list_4 ADD CONSTRAINT emp_list_4_ck CHECK (id IS NOT NULL AND id = 7)
```

**Step 11: Step 2: move the rows and attach in ONE transaction**
```sql
BEGIN
```

**Step 12: …move**
```sql
INSERT INTO lab_part.emp_list_4 SELECT * FROM lab_part.emp_list_default WHERE id = 7
```

**Step 13: …delete from DEFAULT**
```sql
DELETE FROM lab_part.emp_list_default WHERE id = 7
```

**Step 14: …attach**
```sql
ALTER TABLE lab_part.emp_list ATTACH PARTITION lab_part.emp_list_4 FOR VALUES IN (7)
```

**Step 15: …commit**
```sql
COMMIT
```

**Step 16: Verify: 7 now lives in emp_list_4**
```sql
SELECT tableoid::regclass AS partition_name, * FROM lab_part.emp_list WHERE id = 7
```

**Step 17: Hierarchy**
```sql
SELECT relid::regclass AS partition, parentrelid::regclass AS parent, isleaf, level FROM pg_partition_tree('lab_part.emp_list')
```

**Step 18: DETACH emp_list_2: it becomes an ordinary table and leaves the parent**
```sql
ALTER TABLE lab_part.emp_list DETACH PARTITION lab_part.emp_list_2
```

**Step 19: The detached table is still queryable on its own**
```sql
SELECT * FROM lab_part.emp_list_2 ORDER BY id
```

**Step 20: …but the parent no longer returns those rows**
```sql
SELECT count(*) AS rows_for_ids_2_3_5 FROM lab_part.emp_list WHERE id IN (2,3,5)
```


### 4.range — RANGE partitioning
Dates, timestamps, IDs. FROM is inclusive, TO is exclusive; MINVALUE/MAXVALUE; splitting a populated MAXVALUE partition.
- Boundary: FROM inclusive, TO exclusive, so 100 belongs to the second partition.
- MAXVALUE does not replace DEFAULT for uncovered lower ranges; prefer MINVALUE for the first partition.
- Overlapping ranges are rejected. To split a populated MAXVALUE partition: detach it, create the new ones, move the data.
- Create monthly or quarterly partitions ahead of time; avoid leaving a huge MAXVALUE partition for years.

#### EMP lab: boundaries, MINVALUE/MAXVALUE, splitting a range
**Step 1: Clean up any earlier run**
```sql
DROP TABLE IF EXISTS lab_part.emp_range CASCADE; DROP TABLE IF EXISTS lab_part.old_emp_range_3
```

**Step 2: Parent partitioned by RANGE, with MINVALUE / MAXVALUE ends**
```sql
CREATE SCHEMA IF NOT EXISTS lab_part; CREATE TABLE lab_part.emp_range (id int, sal int) PARTITION BY RANGE (id); CREATE TABLE lab_part.emp_range_1 PARTITION OF lab_part.emp_range FOR VALUES FROM (MINVALUE) TO (100); CREATE TABLE lab_part.emp_range_2 PARTITION OF lab_part.emp_range FOR VALUES FROM (100) TO (200); CREATE TABLE lab_part.emp_range_3 PARTITION OF lab_part.emp_range FOR VALUES FROM (200) TO (MAXVALUE)
```

**Step 3: Insert boundary values: FROM is inclusive, TO is exclusive**
```sql
INSERT INTO lab_part.emp_range VALUES (-100,100),(-5,200),(0,300),(25,1000),(75,1500),(99,1800),(100,2000),(125,2500),(199,3000),(200,3500),(250,4000),(500,5000),(1000,100),(999999,300)
```

**Step 4: Routing: 100 is in emp_range_2, not emp_range_1; negatives fall into MINVALUE; big values into MAXVALUE**
```sql
SELECT tableoid::regclass AS partition_name, * FROM lab_part.emp_range ORDER BY id
```

**Step 5: Add a dedicated 300–399 partition directly: overlaps the MAXVALUE partition**
```sql
CREATE TABLE lab_part.emp_range_4 PARTITION OF lab_part.emp_range FOR VALUES FROM (300) TO (400)
```

Expected demonstration error: ERROR: partition "emp_range_4" would overlap partition "emp_range_3"
**Step 6: Correct way: detach the MAXVALUE partition and keep it as the source**
```sql
ALTER TABLE lab_part.emp_range DETACH PARTITION lab_part.emp_range_3; ALTER TABLE lab_part.emp_range_3 RENAME TO old_emp_range_3
```

**Step 7: Create non-overlapping partitions covering the same space**
```sql
CREATE TABLE lab_part.emp_range_3 PARTITION OF lab_part.emp_range FOR VALUES FROM (200) TO (300); CREATE TABLE lab_part.emp_range_4 PARTITION OF lab_part.emp_range FOR VALUES FROM (300) TO (400); CREATE TABLE lab_part.emp_range_5 PARTITION OF lab_part.emp_range FOR VALUES FROM (400) TO (MAXVALUE)
```

**Step 8: Move the data from the old partition**
```sql
INSERT INTO lab_part.emp_range SELECT * FROM lab_part.old_emp_range_3
```

**Step 9: Verify distribution**
```sql
SELECT tableoid::regclass AS partition_name, count(*) FROM lab_part.emp_range GROUP BY 1 ORDER BY 1
```


### 4.hash — HASH partitioning
Even distribution when there is no natural range or list. Prunes on equality only.
- Good for customer, user, tenant and device IDs; poor for audit or time-series tables.
- Changing MODULUS later needs data redistribution: plan it.
- Pruning only on equality: a range on the key scans every partition.

#### EMP lab: MODULUS/REMAINDER, distribution, pruning
**Step 1: Clean up any earlier run**
```sql
DROP TABLE IF EXISTS lab_part.emp_hash CASCADE
```

**Step 2: Parent partitioned by HASH: 4 partitions (MODULUS 4, REMAINDER 0..3)**
```sql
CREATE SCHEMA IF NOT EXISTS lab_part; CREATE TABLE lab_part.emp_hash (id int, sal int) PARTITION BY HASH (id); CREATE TABLE lab_part.emp_hash_p0 PARTITION OF lab_part.emp_hash FOR VALUES WITH (MODULUS 4, REMAINDER 0); CREATE TABLE lab_part.emp_hash_p1 PARTITION OF lab_part.emp_hash FOR VALUES WITH (MODULUS 4, REMAINDER 1); CREATE TABLE lab_part.emp_hash_p2 PARTITION OF lab_part.emp_hash FOR VALUES WITH (MODULUS 4, REMAINDER 2); CREATE TABLE lab_part.emp_hash_p3 PARTITION OF lab_part.emp_hash FOR VALUES WITH (MODULUS 4, REMAINDER 3)
```

**Step 3: Insert 20 rows and look at the routing**
```sql
INSERT INTO lab_part.emp_hash SELECT g, g*100 FROM generate_series(1,20) g; SELECT tableoid::regclass AS partition_name, * FROM lab_part.emp_hash ORDER BY id
```

**Step 4: Insert 100,000 rows: HASH spreads them almost evenly**
```sql
INSERT INTO lab_part.emp_hash SELECT g, g*100 FROM generate_series(21,100000) g; SELECT tableoid::regclass AS partition_name, count(*) FROM lab_part.emp_hash GROUP BY 1 ORDER BY 1
```

**Step 5: Equality on the key prunes to one partition**
```sql
EXPLAIN (COSTS OFF) SELECT * FROM lab_part.emp_hash WHERE id = 42
```

**Step 6: A range on the key cannot prune: every partition is scanned**
```sql
ANALYZE lab_part.emp_hash; EXPLAIN (COSTS OFF) SELECT * FROM lab_part.emp_hash WHERE id BETWEEN 40 AND 50
```


### 4.maintenance — DEFAULT, ATTACH, DETACH & maintenance
The operational side: DEFAULT as a safety net, why it makes ATTACH and DETACH harder, and DROP vs DELETE.
- ATTACH scans the DEFAULT to prove no row belongs to the new range, and is blocked while it holds one.
- DETACH CONCURRENTLY is refused while a DEFAULT partition exists. Plain DETACH works with a stronger lock.
- DROP TABLE on a partition: fast, minimal WAL, no dead tuples, no VACUUM. DELETE of millions of rows is the opposite.
- Monthly job: create next month, verify, archive expired, drop obsolete, notify.

#### Monthly sales: create ahead, attach, detach, archive, drop
**Step 1: Clean up any earlier run**
```sql
DROP TABLE IF EXISTS lab_part.sales CASCADE; DROP TABLE IF EXISTS lab_part.sales_2025_07
```

**Step 2: Monthly RANGE partitions plus a DEFAULT safety net**
```sql
CREATE SCHEMA IF NOT EXISTS lab_part; CREATE TABLE lab_part.sales (id bigint, sale_date date, amount numeric) PARTITION BY RANGE (sale_date); CREATE TABLE lab_part.sales_2025_01 PARTITION OF lab_part.sales FOR VALUES FROM ('2025-01-01') TO ('2025-02-01'); CREATE TABLE lab_part.sales_2025_02 PARTITION OF lab_part.sales FOR VALUES FROM ('2025-02-01') TO ('2025-03-01'); CREATE TABLE lab_part.sales_2025_03 PARTITION OF lab_part.sales FOR VALUES FROM ('2025-03-01') TO ('2025-04-01'); CREATE TABLE lab_part.sales_default PARTITION OF lab_part.sales DEFAULT
```

**Step 3: Insert, including a July row that has no partition yet**
```sql
INSERT INTO lab_part.sales SELECT g, date '2025-01-01' + (g % 90), g FROM generate_series(1,3000) g; INSERT INTO lab_part.sales VALUES (99999, '2025-07-04', 10)
```

**Step 4: Monitor the DEFAULT partition: a growing DEFAULT means future partitions are missing**
```sql
SELECT tableoid::regclass AS partition_name, count(*) FROM lab_part.sales GROUP BY 1 ORDER BY 1
```

**Step 5: ATTACH the July partition while the DEFAULT holds a July row**
```sql
CREATE TABLE lab_part.sales_2025_07 (LIKE lab_part.sales INCLUDING ALL); ALTER TABLE lab_part.sales ATTACH PARTITION lab_part.sales_2025_07 FOR VALUES FROM ('2025-07-01') TO ('2025-08-01')
```

Expected demonstration error: ERROR: updated partition constraint for default partition would be violated by some row
**Step 6: Fix: move the row and attach in one transaction**
```sql
BEGIN
```

**Step 7: …move**
```sql
WITH moved AS (DELETE FROM lab_part.sales_default WHERE sale_date >= '2025-07-01' AND sale_date < '2025-08-01' RETURNING *) INSERT INTO lab_part.sales_2025_07 SELECT * FROM moved
```

**Step 8: …attach**
```sql
ALTER TABLE lab_part.sales ATTACH PARTITION lab_part.sales_2025_07 FOR VALUES FROM ('2025-07-01') TO ('2025-08-01')
```

**Step 9: …commit**
```sql
COMMIT
```

**Step 10: List the partitions**
```sql
SELECT inhrelid::regclass AS partition_name FROM pg_inherits WHERE inhparent = 'lab_part.sales'::regclass ORDER BY 1
```

**Step 11: DETACH ... CONCURRENTLY is refused while a DEFAULT partition exists**
```sql
ALTER TABLE lab_part.sales DETACH PARTITION lab_part.sales_2025_01 CONCURRENTLY
```

Expected demonstration error: ERROR: cannot detach partitions concurrently when a default partition exists
**Step 12: A plain DETACH works (it takes a stronger lock)**
```sql
ALTER TABLE lab_part.sales DETACH PARTITION lab_part.sales_2025_01
```

**Step 13: The detached partition is now an independent table: back it up, archive it, or drop it**
```sql
SELECT count(*) AS archived_rows FROM lab_part.sales_2025_01
```

**Step 14: Dropping a partition is instant: no dead tuples, no VACUUM (unlike DELETE of millions of rows)**
```sql
DROP TABLE lab_part.sales_2025_01
```

**Step 15: Partition sizes**
```sql
SELECT relid::regclass AS partition, pg_size_pretty(pg_total_relation_size(relid)) AS size FROM pg_partition_tree('lab_part.sales') WHERE isleaf ORDER BY 1
```


### 4.pruning — Partition pruning
Planner and executor skip partitions that cannot match. Verify with EXPLAIN, and know what defeats it.
- Pruning is the main performance benefit of partitioning, but a plain B-tree often does the same job as fast. Partitioning's real value is data management.
- A function or cast on the key (extract(), date_trunc() on a timestamptz) disables pruning; rewrite as a half-open range.
- Range boundaries are fixed instants decided by the session TimeZone at creation time.
- Prepared statements still prune at run time ('Subplans Removed').

#### Static, runtime and no pruning (small tables)
**Step 1: Clean up any earlier run**
```sql
DROP TABLE IF EXISTS lab_part.orders_prune CASCADE
```

**Step 2: Yearly RANGE partitions**
```sql
CREATE SCHEMA IF NOT EXISTS lab_part; CREATE TABLE lab_part.orders_prune (id bigint, order_date date, amount numeric) PARTITION BY RANGE (order_date); CREATE TABLE lab_part.orders_prune_2024 PARTITION OF lab_part.orders_prune FOR VALUES FROM ('2024-01-01') TO ('2025-01-01'); CREATE TABLE lab_part.orders_prune_2025 PARTITION OF lab_part.orders_prune FOR VALUES FROM ('2025-01-01') TO ('2026-01-01'); CREATE TABLE lab_part.orders_prune_2026 PARTITION OF lab_part.orders_prune FOR VALUES FROM ('2026-01-01') TO ('2027-01-01'); INSERT INTO lab_part.orders_prune SELECT g, date '2024-01-01' + (g % 1000), g FROM generate_series(1,30000) g; ANALYZE lab_part.orders_prune
```

**Step 3: Static pruning: constant known at plan time, one partition**
```sql
EXPLAIN (COSTS OFF) SELECT * FROM lab_part.orders_prune WHERE order_date = '2025-05-10'
```

**Step 4: No filter on the key: every partition**
```sql
EXPLAIN (COSTS OFF) SELECT * FROM lab_part.orders_prune
```

**Step 5: Function on the key: pruning is lost (extract() hides the column)**
```sql
EXPLAIN (COSTS OFF) SELECT * FROM lab_part.orders_prune WHERE extract(year FROM order_date) = 2025
```

**Step 6: Range rewrite: prunes again**
```sql
EXPLAIN (COSTS OFF) SELECT * FROM lab_part.orders_prune WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01'
```

**Step 7: Runtime pruning: a generic prepared plan cannot prune at plan time, the executor drops partitions at start-up**
```sql
SET plan_cache_mode = force_generic_plan; PREPARE prune_q(date) AS SELECT * FROM lab_part.orders_prune WHERE order_date = $1; EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE prune_q('2025-05-10')
```

**Step 8: Tidy up the session**
```sql
DEALLOCATE prune_q; RESET plan_cache_mode
```


#### Real data: flight by month (postgres_air), your PDF chapter 10
**Partitions and row counts**
```sql
SELECT tableoid::regclass AS partition, count(*) AS rows FROM lab_part.flight_part GROUP BY 1 ORDER BY 1
```

**One-time lab setup** (the app runs this automatically; run manually only if the objects do not exist):
```sql
CREATE SCHEMA IF NOT EXISTS lab_part;
DO $$
DECLARE mn date; mx date; d date;
BEGIN
  IF to_regclass('lab_part.flight_part') IS NOT NULL THEN RETURN; END IF;
  SELECT date_trunc('month', min(scheduled_departure))::date, date_trunc('month', max(scheduled_departure))::date
    INTO mn, mx FROM postgres_air.flight;
  EXECUTE 'CREATE TABLE lab_part.flight_part (LIKE postgres_air.flight INCLUDING DEFAULTS) PARTITION BY RANGE (scheduled_departure)';
  d := mn;
  WHILE d <= mx LOOP
    EXECUTE format('CREATE TABLE lab_part.flight_part_%s PARTITION OF lab_part.flight_part FOR VALUES FROM (%L) TO (%L)',
                   to_char(d, 'YYYYMM'), d, (d + interval '1 month')::date);
    d := (d + interval '1 month')::date;
  END LOOP;
  EXECUTE 'CREATE TABLE lab_part.flight_part_default PARTITION OF lab_part.flight_part DEFAULT';
  EXECUTE 'INSERT INTO lab_part.flight_part SELECT * FROM postgres_air.flight';
  EXECUTE 'ANALYZE lab_part.flight_part';
END $$;
```


**Variant — A original table, month range**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```


**Variant — B partitioned, month range (static pruning)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM lab_part.flight_part WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```


**Variant — C partitioned, date_trunc() on the key (pruning lost)**
```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM lab_part.flight_part WHERE date_trunc('month', scheduled_departure) = '2024-08-01'::timestamptz
```


**Variant — D prepared + generic plan (runtime pruning)**
```sql
SET plan_cache_mode = force_generic_plan;
PREPARE lab_flight_q(timestamptz, timestamptz) AS SELECT count(*) FROM lab_part.flight_part WHERE scheduled_departure >= $1 AND scheduled_departure < $2;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
EXECUTE lab_flight_q('2024-08-01'::timestamptz, '2024-09-01'::timestamptz)
```

```sql
DEALLOCATE lab_flight_q;
RESET plan_cache_mode;
```


**Variant — E B-tree on the original table (for comparison)**
```sql
CREATE INDEX flight_dep_lab_idx ON postgres_air.flight (scheduled_departure);
ANALYZE postgres_air.flight;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM postgres_air.flight WHERE scheduled_departure >= '2024-08-01'::timestamptz AND scheduled_departure < '2024-09-01'::timestamptz
```

```sql
DROP INDEX IF EXISTS postgres_air.flight_dep_lab_idx;
```


### 4.indexes — Indexes & constraints on partitions
Local indexes only: the partition key must be part of every PRIMARY KEY / UNIQUE constraint.
- PostgreSQL has no global indexes: uniqueness cannot be enforced across partitions unless the key includes the partition key.
- Create indexes on the parent: every existing and future partition gets a matching local index.
- Partitioning does not replace indexing: pruning picks the partition, the index finds the rows inside it.
- BRIN suits very large append-only partitions; B-tree for equality, joins and primary keys.

#### orders: PRIMARY KEY, UNIQUE, parent index, foreign key
**Step 1: Clean up any earlier run**
```sql
DROP TABLE IF EXISTS lab_part.orders_p CASCADE; DROP TABLE IF EXISTS lab_part.customers_p CASCADE
```

**Step 2: Partitioned orders by year, 300,000 rows**
```sql
CREATE SCHEMA IF NOT EXISTS lab_part; CREATE TABLE lab_part.orders_p (id bigint, order_date date NOT NULL, customer_id int, amount numeric) PARTITION BY RANGE (order_date); CREATE TABLE lab_part.orders_p_2024 PARTITION OF lab_part.orders_p FOR VALUES FROM ('2024-01-01') TO ('2025-01-01'); CREATE TABLE lab_part.orders_p_2025 PARTITION OF lab_part.orders_p FOR VALUES FROM ('2025-01-01') TO ('2026-01-01'); CREATE TABLE lab_part.orders_p_2026 PARTITION OF lab_part.orders_p FOR VALUES FROM ('2026-01-01') TO ('2027-01-01'); INSERT INTO lab_part.orders_p SELECT g, date '2024-01-01' + (g % 1000), 1 + (g % 100000), g FROM generate_series(1,300000) g
```

**Step 3: PRIMARY KEY (id) alone is invalid: uniqueness cannot be guaranteed across partitions**
```sql
ALTER TABLE lab_part.orders_p ADD PRIMARY KEY (id)
```

Expected demonstration error: ERROR: unique constraint on partitioned table must include all partitioning columns
**Step 4: PRIMARY KEY (id, order_date) includes the partition key**
```sql
ALTER TABLE lab_part.orders_p ADD PRIMARY KEY (id, order_date)
```

**Step 5: UNIQUE (customer_id) without the partition key is rejected too**
```sql
ALTER TABLE lab_part.orders_p ADD UNIQUE (customer_id)
```

Expected demonstration error: ERROR: unique constraint on partitioned table must include all partitioning columns
**Step 6: An index on the parent creates a local index on every partition**
```sql
CREATE INDEX orders_p_customer_idx ON lab_part.orders_p (customer_id); SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'lab_part' AND tablename LIKE 'orders_p%' ORDER BY 1, 2
```

**Step 7: Pruning picks the partition, the index finds the rows inside it**
```sql
ANALYZE lab_part.orders_p; EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM lab_part.orders_p WHERE order_date = '2025-06-01' AND customer_id = 500
```

**Step 8: Foreign key from the partitioned table to a normal table**
```sql
CREATE TABLE lab_part.customers_p (customer_id int PRIMARY KEY); INSERT INTO lab_part.customers_p SELECT g FROM generate_series(1,100000) g; ALTER TABLE lab_part.orders_p ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES lab_part.customers_p (customer_id)
```

**Step 9: Local indexes: one physical index per partition, each small**
```sql
SELECT indexrelid::regclass AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size FROM pg_index WHERE indrelid IN (SELECT relid FROM pg_partition_tree('lab_part.orders_p') WHERE isleaf) ORDER BY 1
```


### 4.wise — Partition-wise join & aggregate
With identically partitioned tables PostgreSQL can join and aggregate partition by partition: smaller joins, less memory, better parallelism.
- Both tables must use the same strategy and compatible boundaries, and join on the partition key.
- Both optimisations are off by default (enable_partitionwise_join / enable_partitionwise_aggregate).
- Full partition-wise aggregation needs GROUP BY on the partition key; otherwise PostgreSQL does partial aggregation per partition.

#### pw_orders (2M) ⋈ pw_payments (4M), both HASH(order_id) × 8
**One-time lab setup** (the app runs this automatically; run manually only if the objects do not exist):
```sql
CREATE SCHEMA IF NOT EXISTS lab_part;
DO $$
DECLARE i int;
BEGIN
  IF to_regclass('lab_part.pw_orders') IS NOT NULL THEN RETURN; END IF;
  EXECUTE 'CREATE TABLE lab_part.pw_orders (order_id bigint, customer_id int, amount numeric(10,2)) PARTITION BY HASH (order_id)';
  EXECUTE 'CREATE TABLE lab_part.pw_payments (payment_id bigint, order_id bigint, paid numeric(10,2)) PARTITION BY HASH (order_id)';
  FOR i IN 0..7 LOOP
    EXECUTE format('CREATE TABLE lab_part.pw_orders_p%s PARTITION OF lab_part.pw_orders FOR VALUES WITH (MODULUS 8, REMAINDER %s)', i, i);
    EXECUTE format('CREATE TABLE lab_part.pw_payments_p%s PARTITION OF lab_part.pw_payments FOR VALUES WITH (MODULUS 8, REMAINDER %s)', i, i);
  END LOOP;
  EXECUTE 'INSERT INTO lab_part.pw_orders SELECT g, (random()*100000)::int, round((random()*500)::numeric, 2) FROM generate_series(1, 2000000) g';
  EXECUTE 'INSERT INTO lab_part.pw_payments SELECT g, 1 + (g % 2000000), round((random()*500)::numeric, 2) FROM generate_series(1, 4000000) g';
  EXECUTE 'ANALYZE lab_part.pw_orders';
  EXECUTE 'ANALYZE lab_part.pw_payments';
END $$;
```


**Variant — Join, partitionwise_join = off**
```sql
SET enable_partitionwise_join = off;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*), sum(p.paid) FROM lab_part.pw_orders o JOIN lab_part.pw_payments p USING (order_id)
```

```sql
RESET ALL;
```


**Variant — Join, partitionwise_join = on**
```sql
SET enable_partitionwise_join = on;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*), sum(p.paid) FROM lab_part.pw_orders o JOIN lab_part.pw_payments p USING (order_id)
```

```sql
RESET ALL;
```


**Variant — Aggregate on the key, partitionwise_aggregate = off**
```sql
SET enable_partitionwise_aggregate = off;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT order_id, sum(paid) FROM lab_part.pw_payments GROUP BY order_id HAVING sum(paid) > 900
```

```sql
RESET ALL;
```


**Variant — Aggregate on the key, partitionwise_aggregate = on**
```sql
SET enable_partitionwise_aggregate = on;
```

```sql
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT order_id, sum(paid) FROM lab_part.pw_payments GROUP BY order_id HAVING sum(paid) > 900
```

```sql
RESET ALL;
```


## 5. pg_stat_statements: validate changes across repeated runs
This extension requires `shared_preload_libraries = 'pg_stat_statements'` in `postgresql.conf` and a PostgreSQL restart. Create the extension in the target database. Then use the app’s pg_stat_statements panel or the queries below to compare workload-level evidence.
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT queryid, calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, shared_blks_hit, shared_blks_read, temp_blks_written, wal_bytes
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 20;
```

For a fair before/after comparison: reset statistics, run the same workload, record mean execution time and blocks per call, make one change, reset again, and repeat. `EXPLAIN ANALYZE` is one execution; workload statistics capture repeated application activity.

## 6. Final checklist for every live experiment
- Capture baseline `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)` before changing anything.
- Change only one thing at a time: index, rewrite, partitioning, or parameter.
- Run `ANALYZE` after creating indexes or loading/changing data.
- Rerun exactly the same query and compare actual rows, plan nodes, buffers, heap blocks, temp blocks, sort method, hash batches, and execution time.
- For alternative indexes, drop competing indexes before judging each one.
- For partition pruning, keep predicates as direct ranges on the partition key; avoid wrapping the key in functions.
- For settings, use session-level `SET`, then `RESET`/`RESET ALL`; avoid changing global production settings based on a single demo.
- Validate query result equivalence before accepting a rewrite.
- Report observed timings as this lab’s measurements, not universal guarantees.

## Appendix A — Relevant setup notes
- `setup_demo.sql` creates `demo.documents`, `demo.restaurants`, `demo.users`, `demo.logs`, `demo.employees`, and helper function `demo.norm_email(text)`. It installs `cube`, `earthdistance`, and `pg_trgm` extensions if needed.
- Default synthetic data sizes: documents 340k, restaurants 2.2M, users 6M, logs 7.5M, employees 4M. The default setup drops and recreates schema `demo`; do not rerun casually if you need to preserve demo data.
- `setup_bigtable.sql` drops and recreates `demo.big_table1` with 5M rows and `idx_big_table1_val`; only run if you are comfortable replacing that lab table.
- The app uses `*_lab_idx` index names and scratch schemas `labx`/`lab_part`. Inspect DDL before using cleanup on a shared lab.
