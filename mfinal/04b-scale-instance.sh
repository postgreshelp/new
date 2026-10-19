#!/usr/bin/env bash
# Vertical scaling with minimal downtime (the standard Aurora pattern):
#   1. resize the READER  -> 2. fail over to it (~30s blip)  -> 3. resize the OLD writer (now a reader)
#   bash 04b-scale-instance.sh                 # to SCALE_TO_CLASS from env.sh (default db.t3.large)
#   bash 04b-scale-instance.sh db.t3.medium    # scale back
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
NEW_CLASS="${1:-$SCALE_TO_CLASS}"
lab_init "Scale instances to $NEW_CLASS"
need_endpoints
[[ "$(cluster_status)" == available ]] || die "Cluster must be available"

WRITER=$(current_writer)
READER=$(cq 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`false`] | sort_by(@,&PromotionTier)[0].DBInstanceIdentifier')
[[ -n "$READER" && "$READER" != None ]] || die "Needs at least one reader for the zero-ish downtime pattern"
OK_CLASS=$(aws rds describe-orderable-db-instance-options --engine aurora-postgresql --engine-version "$(cq 'DBClusters[0].EngineVersion')" \
  --db-instance-class "$NEW_CLASS" --region "$AWS_REGION" --query 'length(OrderableDBInstanceOptions)' --output text 2>/dev/null || echo 0)
[[ "$OK_CLASS" != 0 ]] || die "$NEW_CLASS is not orderable for this engine version in $AWS_REGION"

step "Plan"
info "Writer $WRITER ($(iq 'DBInstances[0].DBInstanceClass' "$WRITER"))  Reader $READER ($(iq 'DBInstances[0].DBInstanceClass' "$READER"))"
info "1) modify $READER -> $NEW_CLASS   2) failover to $READER   3) modify $WRITER -> $NEW_CLASS"
info "Downtime: only the failover blip. Modifying an instance in place = reboot of that instance."
info "Tip: watch it with the probe loop from 04-failover-demo.sh in a second terminal."
confirm "Scale both instances to $NEW_CLASS"

resize() {  # resize <instance>
  local i="$1"
  if [[ "$(iq 'DBInstances[0].DBInstanceClass' "$i")" == "$NEW_CLASS" ]]; then ok "$i already $NEW_CLASS"; return; fi
  aws rds modify-db-instance --db-instance-identifier "$i" --db-instance-class "$NEW_CLASS" --apply-immediately --region "$AWS_REGION" >/dev/null
  ok "$i: modify requested"
  sleep 20
  poll "$i" "available" 1800 instance_status "$i" || die "$i did not become available"
  [[ "$(iq 'DBInstances[0].DBInstanceClass' "$i")" == "$NEW_CLASS" ]] && ok "$i is now $NEW_CLASS" || die "$i class did not change"
}
step "1. Resize reader $READER (applications on the writer are unaffected)"
resize "$READER"
step "2. Fail over to $READER"
aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER_ID" --target-db-instance-identifier "$READER" --region "$AWS_REGION" >/dev/null
poll "writer" "$READER" 600 current_writer || die "Failover did not complete"
ok "$READER ($NEW_CLASS) is the writer"
poll "cluster" "available" 600 cluster_status || true
step "3. Resize old writer $WRITER (now a reader)"
resize "$WRITER"

step "Verify"
aws rds describe-db-instances --filters "Name=db-cluster-id,Values=$CLUSTER_ID" --region "$AWS_REGION" \
  --query 'DBInstances[].{Instance:DBInstanceIdentifier,Class:DBInstanceClass,Status:DBInstanceStatus}' --output table
db_check "Writer endpoint" "$CLUSTER_WRITER" || true
can_sql && info "max_connections now: $(sql "$CLUSTER_WRITER" "show max_connections") (derived from instance memory unless set in a parameter group)"
info "Optional: fail back so $WRITER is writer again: bash 04-failover-demo.sh"
lab_next "bash 04b-scale-instance.sh $DB_INSTANCE_CLASS   # scale back down (cost)"
lab_success "both instances are $NEW_CLASS; writer is $READER"
