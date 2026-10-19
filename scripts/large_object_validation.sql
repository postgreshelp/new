-- Requires pgcrypto and a table with file_name and lo_oid columns.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT file_id, file_name, octet_length(lo_get(lo_oid)) AS bytes,
       encode(digest(lo_get(lo_oid), 'sha256'), 'hex') AS sha256
FROM uploaded_file ORDER BY file_id;
