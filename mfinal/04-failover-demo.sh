#!/usr/bin/env bash
# Manual failover to the current reader, timed, then verified through the cluster endpoint.
# Works repeatedly (always picks whichever instance is a reader right now).
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Failover demo"

need_endpoints
[[ "$(cluster_status)" == available ]] || die "Cluster must be 'available' (now: $(cluster_status))"
OLD_WRITER=$(current_writer)
TARGET=$(cq 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`false`] | sort_by(@,&PromotionTier)[0].DBInstanceIdentifier')
[[ "$TARGET" == None ]] && TARGET=""
[[ -n "$TARGET" ]] || die "No reader instance to fail over to. Add one or run 02-create-cluster.sh"

step "Before"
ok "Writer now: $OLD_WRITER   ->   new writer will be: $TARGET"
OLD_IP=""; can_sql && OLD_IP=$(sql "$CLUSTER_WRITER" "select inet_server_addr()" 2>/dev/null || true)
[[ -n "$OLD_IP" ]] && info "Cluster endpoint currently lands on $OLD_IP"

step "Watch it from the client side (open a 2nd terminal and paste BEFORE confirming)"
cmd "while true; do psql \"$(conninfo "$CLUSTER_WRITER") connect_timeout=2\" -XAtc \"select now()::time(0), inet_server_addr(), case when pg_is_in_recovery() then 'reader' else 'writer' end\" 2>&1 | head -1; sleep 1; done"
info "Through RDS Proxy instead (on the client EC2): bash 10b-proxy-demo.sh failover"
confirm "Fail over $CLUSTER_ID now (active sessions are dropped)"

step "Failover"
T0=$(date +%s)
aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER_ID" --target-db-instance-identifier "$TARGET" --region "$AWS_REGION" >/dev/null
ok "Failover requested at $(date +%H:%M:%S)"
poll "writer according to AWS" "$TARGET" 600 current_writer || die "Writer did not change to $TARGET"
T_API=$(( $(date +%s) - T0 ))
ok "AWS reports $TARGET as writer after ~${T_API}s"

step "Verify through the cluster endpoint"
if can_sql; then
  for ((i = 0; i < 60; i++)); do
    R=$(sql "$CLUSTER_WRITER" "select inet_server_addr()||' '||pg_is_in_recovery()" 2>/dev/null || true)
    [[ "$R" == *" f" ]] && break
    sleep 2
  done
  T_SQL=$(( $(date +%s) - T0 ))
  if [[ "$R" == *" f" ]]; then ok "Cluster endpoint accepts writes again after ~${T_SQL}s (server ${R% *}${OLD_IP:+, was $OLD_IP})"
  else warn "Cluster endpoint not writable yet (last answer: '${R:-no connection}'); DNS may still be updating"; fi
else
  warn "psql/PGPASSWORD not available; skipped SQL verification"
fi
poll "cluster status" "available" 600 cluster_status || true

step "After"
aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" \
  --query 'DBClusters[0].DBClusterMembers[].{Instance:DBInstanceIdentifier,Writer:IsClusterWriter,Tier:PromotionTier}' --output table
info "Teaching points: endpoint name never changed; the old writer ($OLD_WRITER) came back as a reader;"
info "instance names don't follow roles, so apps must use the cluster endpoint, not instance endpoints."

lab_next "bash 04-failover-demo.sh     # again: fails back to $OLD_WRITER" "bash 05-parameter-groups.sh"
lab_success "failover $OLD_WRITER -> $TARGET in ~${T_API}s (AWS view)"
