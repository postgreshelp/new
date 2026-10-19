-- Run on source and restored target; compare output manifests.
SELECT count(*) AS rows, sum(length(body)) AS body_chars,
       sum(octet_length(payload)) AS payload_bytes
FROM demo.documents;
SELECT document_id, md5(body), octet_length(payload)
FROM demo.documents ORDER BY document_id;
