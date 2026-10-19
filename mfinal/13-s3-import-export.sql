-- S3 import/export with the aws_s3 extension. Re-runnable (recreates the staging table).
-- 12-s3-prerequisites.sh runs this for you and prints the exact psql command.
-- Variables: s3_bucket, s3_key, s3_export_key, aws_region
\set ON_ERROR_STOP on
\echo '--- extension'
CREATE EXTENSION IF NOT EXISTS aws_s3 CASCADE;

\echo '--- target table (primary key: required later for Blue/Green UPDATE/DELETE replication)'
CREATE SCHEMA IF NOT EXISTS staging;
DROP TABLE IF EXISTS staging.organizations;   -- re-runnable; also replaces the old version without a primary key
CREATE TABLE staging.organizations (
  organization_id   int PRIMARY KEY,
  organization_name text NOT NULL
);

\echo '--- import s3://' :s3_bucket '/' :s3_key
SELECT aws_s3.table_import_from_s3(
  'staging.organizations', '', '(format csv, header true)',
  aws_commons.create_s3_uri(:'s3_bucket', :'s3_key', :'aws_region')
) AS import_result;
SELECT count(*) AS imported_rows FROM staging.organizations;
SELECT * FROM staging.organizations ORDER BY organization_id;

\echo '--- export to s3://' :s3_bucket '/' :s3_export_key
SELECT rows_uploaded, files_uploaded, bytes_uploaded
FROM aws_s3.query_export_to_s3(
  'SELECT * FROM staging.organizations ORDER BY organization_id',
  aws_commons.create_s3_uri(:'s3_bucket', :'s3_export_key', :'aws_region'),
  options := 'format csv, header true'
);
