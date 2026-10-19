# PostgreSQL upgrade and migration change checklist

- [ ] Change ticket, owner, reviewer and approved maintenance window recorded.
- [ ] Exact source/target versions and binary paths verified.
- [ ] Vendor/extension compatibility matrix approved.
- [ ] Backup and every tablespace volume included; restore rehearsal passed.
- [ ] Source configuration, roles, tablespaces, extensions and replication topology inventoried.
- [ ] `pg_upgrade --check` clean and logs retained.
- [ ] Application writes frozen; jobs, poolers and HA automation handled.
- [ ] Target starts with no fatal errors.
- [ ] Databases, schemas, roles, grants, extensions, collations, tablespaces validated.
- [ ] Critical row counts, aggregates, checksums and business invariants match.
- [ ] Sequences, large objects, logical slots/subscriptions and physical standbys explicitly validated.
- [ ] Analyze/statistics and performance baseline completed.
- [ ] Backup/archive/monitoring/alerts verified on target.
- [ ] Application smoke tests and connection pool tests pass.
- [ ] Rollback decision point, data-divergence rule and owner documented.
- [ ] Old cluster cleanup deferred until rollback is formally waived.
- [ ] Final sign-off recorded.
