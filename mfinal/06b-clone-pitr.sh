#!/usr/bin/env bash
# Aurora clone and point-in-time restore, each verified with SQL.
#   bash 06b-clone-pitr.sh clone     # copy-on-write clone; prove it's independent of the source
#   bash 06b-clone-pitr.sh pitr      # create table -> "accidentally" DROP it -> restore to the second before -> rows are back
#   bash 06b-clone-pitr.sh cleanup   # delete the clone and PITR clusters (also done by 90-teardown.sh)
# Needs psql + PGPASSWORD (env.sh) for the SQL proof steps.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-}"
case "$ACTION" in clone|pitr|cleanup) ;; *) echo "Usage: bash $0 {clone|pitr|cleanup}"; exit 2;; esac
lab_init "Clone / PITR: $ACTION"

# Restored and cloned clusters come back with NO instances; this adds one and waits.
add_instance() {  # add_instance <cluster> -> prints nothing, sets NEW_ENDPOINT
  local c="$1" inst="$1-instance"
  aws rds create-db-instance --db-instance-identifier "$inst" --db-cluster-identifier "$c" --engine aurora-postgresql \
    --db-instance-class "$DB_INSTANCE_CLASS" "$(access_flag)" --region "$AWS_REGION" \
    --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
  ok "Instance $inst requested (a restored/cloned cluster has no compute until you add it)"
  poll "instance $inst" "available" 1800 instance_status "$inst" || die "$inst did not become available"
  NEW_ENDPOINT=$(cq 'DBClusters[0].Endpoint' "$c")
}
delete_cluster() {  # delete_cluster <cluster>
  local c="$1" i
  cluster_exists "$c" || { info "$c: not present"; return 0; }
  aws rds modify-db-cluster --db-cluster-identifier "$c" --no-deletion-protection --apply-immediately --region "$AWS_REGION" >/dev/null 2>&1 || true
  for i in $(cluster_instances "$c"); do
    try "delete instance $i" aws rds delete-db-instance --db-instance-identifier "$i" --skip-final-snapshot --region "$AWS_REGION"
  done
  for i in $(cluster_instances "$c"); do aws rds wait db-instance-deleted --db-instance-identifier "$i" --region "$AWS_REGION" || true; done
  try "delete cluster $c" aws rds delete-db-cluster --db-cluster-identifier "$c" --skip-final-snapshot --region "$AWS_REGION"
  aws rds wait db-cluster-deleted --db-cluster-identifier "$c" --region "$AWS_REGION" 2>/dev/null || true
  cluster_exists "$c" && warn "$c still exists" || ok "$c deleted"
  aws logs delete-log-group --log-group-name "/aws/rds/cluster/$c/postgresql" --region "$AWS_REGION" >/dev/null 2>&1 || true
}
restore_args=(--db-subnet-group-name "$DB_SUBNET_GROUP" --vpc-security-group-ids "${SG_ID:?SG_ID empty}" \
              --db-cluster-parameter-group-name "$CLUSTER_PG" --enable-cloudwatch-logs-exports postgresql \
              --tags Key=Project,Value=MyBankAuroraWorkshop --region "$AWS_REGION")

if [[ "$ACTION" == cleanup ]]; then
  confirm "Delete $CLONE_ID and $PITR_ID (if present)"
  step "Delete clone";        delete_cluster "$CLONE_ID"
  step "Delete PITR cluster"; delete_cluster "$PITR_ID"
  lab_next "bash 00-inventory.sh"
  lab_success "clone/PITR clusters removed"; exit 0
fi

need_endpoints
[[ "$(cluster_status)" == available ]] || die "Source cluster must be available"
can_sql || die "This lab proves the result with SQL: set PGPASSWORD in env.sh (and install psql)"

# ------------------------------------------------------------------ clone
if [[ "$ACTION" == clone ]]; then
  cluster_exists "$CLONE_ID" && die "$CLONE_ID already exists. Remove it: bash $0 cleanup"
  info "A clone shares the source's storage pages and only stores pages that change afterwards (copy-on-write)."
  info "Typical uses: test a migration on real data, give a developer a copy, run heavy reports off-production."
  confirm "Create clone $CLONE_ID of $CLUSTER_ID (~10-15 min, billable while it exists)"

  step "Marker row in the source BEFORE cloning"
  sql "$CLUSTER_WRITER" "create table if not exists clone_demo(id bigint generated always as identity primary key, note text, at timestamptz default now())" >/dev/null
  sql "$CLUSTER_WRITER" "insert into clone_demo(note) values ('before clone')" >/dev/null
  ok "clone_demo rows in source: $(sql "$CLUSTER_WRITER" "select count(*) from clone_demo")"

  step "Clone"
  aws rds restore-db-cluster-to-point-in-time --source-db-cluster-identifier "$CLUSTER_ID" --db-cluster-identifier "$CLONE_ID" \
    --restore-type copy-on-write --use-latest-restorable-time "${restore_args[@]}" >/dev/null
  ok "Clone requested"
  poll "clone $CLONE_ID" "available" 1800 cluster_status "$CLONE_ID" || die "Clone did not become available"
  add_instance "$CLONE_ID"; CLONE_ENDPOINT="$NEW_ENDPOINT"

  step "Prove the clone is independent"
  sql "$CLUSTER_WRITER" "insert into clone_demo(note) values ('after clone - source only')" >/dev/null
  sql "$CLONE_ENDPOINT" "insert into clone_demo(note) values ('after clone - clone only')" >/dev/null
  SRC=$(sql "$CLUSTER_WRITER" "select string_agg(note, ' | ' order by id) from clone_demo")
  CLN=$(sql "$CLONE_ENDPOINT" "select string_agg(note, ' | ' order by id) from clone_demo")
  info "source: $SRC"
  info "clone : $CLN"
  [[ "$SRC" == *"source only"* && "$CLN" != *"source only"* && "$CLN" == *"clone only"* ]] \
    && ok "Same starting data, then each side changes independently" || die "Unexpected clone contents"

  step "Connect (copy-paste)"
  show_endpoint "Clone writer:" "$CLONE_ENDPOINT"; password_hint
  lab_next "bash $0 pitr" "bash $0 cleanup     # when done (clone bills while it exists)"
  lab_success "clone $CLONE_ID created and verified"; exit 0
fi

# ------------------------------------------------------------------ pitr
cluster_exists "$PITR_ID" && die "$PITR_ID already exists. Remove it: bash $0 cleanup"
info "Scenario: someone drops an important table. We restore the cluster to the second before the DROP."
confirm "Run the PITR scenario (creates and drops table pitr_demo, restores to $PITR_ID ~15-20 min)"

step "1. Important data"
sql "$CLUSTER_WRITER" "drop table if exists pitr_demo; create table pitr_demo(id int primary key, customer text); insert into pitr_demo select g, 'customer '||g from generate_series(1,1000) g" >/dev/null
ROWS=$(sql "$CLUSTER_WRITER" "select count(*) from pitr_demo")
GOOD_TIME=$(sql "$CLUSTER_WRITER" "select to_char(now() at time zone 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
ok "pitr_demo has $ROWS rows. Good point in time (UTC): $GOOD_TIME"
sleep 5

step "2. The accident"
sql "$CLUSTER_WRITER" "drop table pitr_demo" >/dev/null
EXISTS=$(sql "$CLUSTER_WRITER" "select to_regclass('public.pitr_demo') is not null")
[[ "$EXISTS" == f ]] && ok "DROP TABLE pitr_demo done at $(date -u +%H:%M:%SZ) — table is gone from production" || die "Drop failed?"

step "3. Wait until $GOOD_TIME is inside the restorable window"
lrt_ok() {  # prints 'ready' once LatestRestorableTime >= GOOD_TIME
  python3 - "$(cq 'DBClusters[0].LatestRestorableTime')" "$GOOD_TIME" <<'PY'
import sys, datetime as d
p = lambda s: d.datetime.fromisoformat(s.replace("Z", "+00:00"))
try: print("ready" if p(sys.argv[1]) >= p(sys.argv[2]) else "LatestRestorableTime=" + sys.argv[1][11:19])
except Exception: print("waiting")
PY
}
poll "restore window" "ready" 900 lrt_ok || die "LatestRestorableTime never reached $GOOD_TIME"
ok "Restorable"

step "4. Restore to $GOOD_TIME as a NEW cluster $PITR_ID"
aws rds restore-db-cluster-to-point-in-time --source-db-cluster-identifier "$CLUSTER_ID" --db-cluster-identifier "$PITR_ID" \
  --restore-to-time "$GOOD_TIME" "${restore_args[@]}" >/dev/null
ok "Restore requested (PITR never overwrites the source; it always creates a new cluster)"
poll "PITR cluster $PITR_ID" "available" 2400 cluster_status "$PITR_ID" || die "PITR cluster did not become available"
add_instance "$PITR_ID"; PITR_ENDPOINT="$NEW_ENDPOINT"

step "5. Verify"
GOT=$(sql "$PITR_ENDPOINT" "select count(*) from pitr_demo" 2>&1 || true)
[[ "$GOT" == "$ROWS" ]] && ok "pitr_demo is back in $PITR_ID with $GOT rows" || die "Expected $ROWS rows in restored pitr_demo, got: $GOT"

step "6. Copy the table back into production (copy-paste)"
cmd "pg_dump \"$(conninfo "$PITR_ENDPOINT")\" -t pitr_demo | psql \"$(conninfo "$CLUSTER_WRITER")\""
show_endpoint "Restored cluster:" "$PITR_ENDPOINT"; password_hint

lab_next "pg_dump ... | psql ...   # command above, to repair production" "bash $0 cleanup"
lab_success "point-in-time restore recovered $GOT rows dropped from production"
