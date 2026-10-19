-- Run with psql against the Aurora writer endpoint.
-- Introductory comparison: familiar PostgreSQL operations that still work.
SELECT version();
SHOW server_version;
SELECT current_database(), current_user, inet_server_addr(), inet_server_port();

-- Aurora-managed storage does not mean PostgreSQL SQL disappears.
CREATE TABLE IF NOT EXISTS aurora_intro_demo (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO aurora_intro_demo(note) VALUES
  ('On-prem DBA: familiar SQL'),
  ('Aurora DBA: managed distributed storage and managed operations');
SELECT * FROM aurora_intro_demo ORDER BY id;

-- This shows the current database size, not the full billed Aurora cluster volume.
SELECT pg_size_pretty(pg_database_size(current_database())) AS current_database_size;

-- Clean up the demo objects when finished:
-- DROP TABLE aurora_intro_demo;
