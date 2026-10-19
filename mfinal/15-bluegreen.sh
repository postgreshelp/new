#!/usr/bin/env bash
# Blue/Green deployment, start to finish (run 14-bluegreen-ready.sh first):
#   bash 15-bluegreen.sh create       # create green (BG_TARGET_ENGINE_VERSION) and WAIT until AVAILABLE (~20-40 min)
#   bash 15-bluegreen.sh status       # deployment status + tasks + both clusters
#   bash 15-bluegreen.sh demo         # row written on blue appears on green; writes on green are refused
#   bash 15-bluegreen.sh switchover   # promote green; verify same endpoint, new version
#   bash 15-bluegreen.sh cleanup      # before switchover: delete deployment + green
#                                     # after switchover : delete deployment (keep new prod) + delete old blue (*-old1)
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-status}"
lab_init "Blue/Green: $ACTION"

bg_id()     { aws rds describe-blue-green-deployments --region "$AWS_REGION" --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].BlueGreenDeploymentIdentifier | [0]" --output text 2>/dev/null | sed 's/^None$//'; }
bg_q()      { aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$BG_ID" --region "$AWS_REGION" --query "BlueGreenDeployments[0].$1" --output text 2>/dev/null; }
bg_status() { bg_q Status || echo DELETED; }
green_id()  { local a; a=$(bg_q Target); echo "${a##*:cluster:}"; }
show_bg() {
  aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$BG_ID" --region "$AWS_REGION" \
    --query 'BlueGreenDeployments[0].{Name:BlueGreenDeploymentName,Status:Status,Details:StatusDetails}' --output table
  aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$BG_ID" --region "$AWS_REGION" \
    --query 'BlueGreenDeployments[0].Tasks[].{Task:Name,Status:Status}' --output table 2>/dev/null || true
}
probe_hint() {
  info "Watch from the client side (2nd terminal, paste BEFORE confirming):"
  cmd "while true; do psql \"$(conninfo "$CLUSTER_WRITER") connect_timeout=2\" -XAtc \"select now()::time(0), inet_server_addr(), current_setting('server_version'), case when pg_is_in_recovery() then 'reader' else 'writer' end\" 2>&1 | head -1; sleep 1; done"
}
delete_cluster() {  # delete_cluster <id>: disable protection, delete instances, delete cluster, wait
  local c="$1" i
  cluster_exists "$c" || { ok "$c not present"; return 0; }
  aws rds modify-db-cluster --db-cluster-identifier "$c" --no-deletion-protection --apply-immediately --region "$AWS_REGION" >/dev/null 2>&1 || true
  for i in $(cluster_instances "$c"); do try "delete instance $i" aws rds delete-db-instance --db-instance-identifier "$i" --skip-final-snapshot --region "$AWS_REGION"; done
  for i in $(cluster_instances "$c"); do aws rds wait db-instance-deleted --db-instance-identifier "$i" --region "$AWS_REGION" 2>/dev/null || true; done
  try "delete cluster $c" aws rds delete-db-cluster --db-cluster-identifier "$c" --skip-final-snapshot --region "$AWS_REGION"
  aws rds wait db-cluster-deleted --db-cluster-identifier "$c" --region "$AWS_REGION" 2>/dev/null || true
  cluster_exists "$c" && warn "$c still exists" || ok "$c deleted"
  aws logs delete-log-group --log-group-name "/aws/rds/cluster/$c/postgresql" --region "$AWS_REGION" >/dev/null 2>&1 || true
}
BG_ID=$(bg_id)

case "$ACTION" in
# ------------------------------------------------------------------ create
create)
  need_endpoints
  if [[ -n "$BG_ID" ]]; then ok "Deployment $BG_NAME already exists ($BG_ID, $(bg_status))"
  else
    bash ./14-bluegreen-ready.sh </dev/null >/tmp/bg-ready.log 2>&1 && ok "Readiness check passed (14-bluegreen-ready.sh)" \
      || { tail -25 /tmp/bg-ready.log; die "Readiness check failed — run: bash 14-bluegreen-ready.sh"; }
    info "Green = copy of $CLUSTER_ID kept in sync by logical replication, then upgraded to ${BG_TARGET_ENGINE_VERSION:-same version}."
    info "Billable: doubles the cluster while it exists. Takes ~20-40 min. NO DDL on blue until cleanup."
    confirm "Create Blue/Green deployment $BG_NAME"
    ARGS=(--blue-green-deployment-name "$BG_NAME" --source "$(cq 'DBClusters[0].DBClusterArn')" --region "$AWS_REGION"
          --tags Key=Project,Value=MyBankAuroraWorkshop)
    [[ -n "${BG_TARGET_ENGINE_VERSION:-}" ]] && ARGS+=(--target-engine-version "$BG_TARGET_ENGINE_VERSION")
    aws rds create-blue-green-deployment "${ARGS[@]}" >/dev/null
    BG_ID=$(bg_id); ok "Create requested: $BG_ID"
  fi
  poll "deployment $BG_NAME" "AVAILABLE" 3600 bg_status || { show_bg; die "Deployment did not reach AVAILABLE (status $(bg_status))"; }
  GREEN=$(green_id); GREEN_EP=$(cq 'DBClusters[0].Endpoint' "$GREEN")
  step "Verify"
  ok "Green cluster $GREEN: $(cq 'DBClusters[0].EngineVersion' "$GREEN") (blue: $(cq 'DBClusters[0].EngineVersion'))"
  db_check "Green writer endpoint" "$GREEN_EP" || true
  show_endpoint "Blue (production):" "$CLUSTER_WRITER"; show_endpoint "Green (read-only copy):" "$GREEN_EP"; password_hint
  lab_next "bash $0 demo" "bash $0 switchover"
  lab_success "Blue/Green deployment AVAILABLE; green runs $(cq 'DBClusters[0].EngineVersion' "$GREEN")" ;;
# ------------------------------------------------------------------ status
status)
  [[ -n "$BG_ID" ]] || { ok "No deployment named $BG_NAME"; lab_next "bash 14-bluegreen-ready.sh"; lab_success "nothing deployed"; exit 0; }
  show_bg
  GREEN=$(green_id)
  for c in "$CLUSTER_ID" "$GREEN" "${CLUSTER_ID}-old1"; do
    cluster_exists "$c" && printf '  %-40s %-12s %s\n' "$c" "$(cluster_status "$c")" "$(cq 'DBClusters[0].EngineVersion' "$c")"
  done
  lab_success "status: $(bg_status)" ;;
# ------------------------------------------------------------------ demo
demo)
  need_endpoints
  [[ -n "$BG_ID" && "$(bg_status)" == AVAILABLE ]] || die "Needs an AVAILABLE deployment: bash $0 create"
  can_sql || die "Needs psql + PGPASSWORD"
  GREEN=$(green_id); GREEN_EP=$(cq 'DBClusters[0].Endpoint' "$GREEN")
  [[ "$(sql "$CLUSTER_WRITER" "select to_regclass('public.bg_demo') is not null")" == t ]] || die "bg_demo table missing (14-bluegreen-ready.sh creates it before the deployment)"
  step "1. Versions"
  info "blue : $(sql "$CLUSTER_WRITER" "select current_setting('server_version')")"
  info "green: $(sql "$GREEN_EP" "select current_setting('server_version')")"
  step "2. Write on blue, read on green"
  ID=$(sql "$CLUSTER_WRITER" "insert into bg_demo(note) values ('written on blue at '||now()::time(0)) returning id")
  ok "Inserted id=$ID on blue"
  T0=$(date +%s); SEEN=""
  for ((i = 0; i < 30; i++)); do SEEN=$(sql "$GREEN_EP" "select note from bg_demo where id=$ID" 2>/dev/null || true); [[ -n "$SEEN" ]] && break; sleep 1; done
  [[ -n "$SEEN" ]] && ok "Green has it after ~$(( $(date +%s) - T0 ))s: '$SEEN'" || die "Row not replicated to green within 30s (check: bash $0 status)"
  step "3. Try to write on green"
  OUT=$(sql "$GREEN_EP" "insert into bg_demo(note) values ('written on green')" 2>&1 || true)
  [[ "$OUT" == *read-only* ]] && ok "Refused: ${OUT:0:110}" || warn "Unexpected: ${OUT:0:150}"
  info "Green is read-only until switchover, so the copy can't drift from production."
  show_endpoint "Green:" "$GREEN_EP"
  lab_next "bash $0 switchover"
  lab_success "replication blue -> green verified; green is read-only" ;;
# ------------------------------------------------------------------ switchover
switchover)
  need_endpoints
  [[ -n "$BG_ID" ]] || die "No deployment named $BG_NAME"
  [[ "$(bg_status)" == AVAILABLE ]] || die "Status is $(bg_status), must be AVAILABLE"
  OLD_VER=$(cq 'DBClusters[0].EngineVersion'); GREEN=$(green_id); NEW_VER=$(cq 'DBClusters[0].EngineVersion' "$GREEN")
  info "Switchover: writes are blocked briefly, green catches up, names swap:"
  info "  $GREEN -> $CLUSTER_ID (new production, $NEW_VER)   and   $CLUSTER_ID -> ${CLUSTER_ID}-old1 ($OLD_VER)"
  info "Typical downtime under a minute. Endpoints keep their names, so apps need no change."
  probe_hint
  confirm "Switch over now"
  T0=$(date +%s)
  aws rds switchover-blue-green-deployment --blue-green-deployment-identifier "$BG_ID" --switchover-timeout 300 --region "$AWS_REGION" >/dev/null
  ok "Switchover requested"
  poll "deployment" "SWITCHOVER_COMPLETED SWITCHOVER_FAILED" 1200 bg_status || true
  ST=$(bg_status); [[ "$ST" == SWITCHOVER_COMPLETED ]] || { show_bg; die "Switchover ended with $ST (production stays on blue if it failed)"; }
  ok "Switchover completed in ~$(( $(date +%s) - T0 ))s"
  step "Verify"
  ok "$CLUSTER_ID now runs $(cq 'DBClusters[0].EngineVersion') (was $OLD_VER); old blue is ${CLUSTER_ID}-old1 ($(cluster_status "${CLUSTER_ID}-old1"))"
  if can_sql; then
    for ((i = 0; i < 30; i++)); do V=$(sql "$CLUSTER_WRITER" "select current_setting('server_version')" 2>/dev/null || true); [[ "$V" == "$NEW_VER"* ]] && break; sleep 2; done
    [[ "$V" == "$NEW_VER"* ]] && ok "Same endpoint $CLUSTER_WRITER now answers with version $V" || warn "Endpoint answered '$V' (DNS may still be updating)"
    N=$(sql "$CLUSTER_WRITER" "select count(*) from bg_demo" 2>/dev/null || echo '?'); ok "bg_demo rows on new production: $N"
  fi
  info "Old blue keeps running and billing until cleanup. Auto scaling must be re-applied (bash 11-reader-autoscaling.sh)."
  lab_next "bash $0 cleanup     # delete the deployment and ${CLUSTER_ID}-old1" "bash 03-status.sh"
  lab_success "switched over to $NEW_VER" ;;
# ------------------------------------------------------------------ cleanup
cleanup)
  if [[ -z "$BG_ID" ]]; then
    ok "No deployment named $BG_NAME"
  else
    ST=$(bg_status); GREEN=$(green_id)
    if [[ "$ST" == SWITCHOVER_COMPLETED ]]; then
      info "After switchover: delete only the deployment record (--no-delete-target keeps the new production), then old blue."
      confirm "Delete deployment $BG_NAME and old cluster ${CLUSTER_ID}-old1"
      aws rds delete-blue-green-deployment --blue-green-deployment-identifier "$BG_ID" --no-delete-target --region "$AWS_REGION" >/dev/null
    else
      info "Before switchover ($ST): delete the deployment AND the green cluster $GREEN; production is untouched."
      confirm "Delete deployment $BG_NAME and green cluster $GREEN"
      aws rds delete-blue-green-deployment --blue-green-deployment-identifier "$BG_ID" --delete-target --region "$AWS_REGION" >/dev/null
    fi
    ok "Delete requested"
    poll "deployment" "DELETED" 1800 bg_status || die "Deployment still exists"
    if [[ "$ST" != SWITCHOVER_COMPLETED && -n "$GREEN" ]]; then
      poll "green cluster $GREEN (deleted by AWS with --delete-target)" "not-found" 2400 cluster_status "$GREEN" \
        || { warn "Green still exists; deleting it explicitly"; delete_cluster "$GREEN"; }
    fi
  fi
  if cluster_exists "${CLUSTER_ID}-old1"; then
    step "Old blue ${CLUSTER_ID}-old1"
    [[ -n "$BG_ID" ]] || confirm "Delete leftover old cluster ${CLUSTER_ID}-old1"
    delete_cluster "${CLUSTER_ID}-old1"
  fi
  step "Verify"
  [[ -z "$(bg_id)" ]] && ok "No Blue/Green deployment left" || warn "Deployment still listed"
  cluster_exists "${CLUSTER_ID}-old1" && warn "${CLUSTER_ID}-old1 still exists" || ok "No -old1 cluster"
  ok "Production $CLUSTER_ID: $(cluster_status) $(cq 'DBClusters[0].EngineVersion')"
  lab_next "bash 03-status.sh"
  lab_success "Blue/Green cleaned up" ;;
*) die "Usage: bash $0 {create|status|demo|switchover|cleanup}" ;;
esac
