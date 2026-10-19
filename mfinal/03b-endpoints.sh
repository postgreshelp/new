#!/usr/bin/env bash
# Aurora endpoints in practice:
#   bash 03b-endpoints.sh demo     # reader endpoint spreads NEW connections over readers (needs 2+ readers to see it)
#   bash 03b-endpoints.sh create   # custom endpoint "reporting" pinned to one chosen reader, then prove it
#   bash 03b-endpoints.sh delete
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-demo}"
lab_init "Endpoints: $ACTION"
need_endpoints
ep_status() { aws rds describe-db-cluster-endpoints --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION" --query 'DBClusterEndpoints[0].Status' --output text 2>/dev/null || echo not-found; }

# connect N times to <host>; print which server answered each time
spread() {  # spread <host> <n>
  local i ip; declare -A seen=()
  for ((i = 1; i <= $2; i++)); do
    ip=$(sql "$1" "select inet_server_addr()" 2>/dev/null || echo fail); seen[$ip]=$(( ${seen[$ip]:-0} + 1 ))
  done
  for ip in "${!seen[@]}"; do printf '          %-16s answered %s time(s)\n' "$ip" "${seen[$ip]}"; done
  SPREAD_DISTINCT=${#seen[@]}
}

case "$ACTION" in
demo)
  can_sql || die "Needs psql + PGPASSWORD in env.sh"
  READERS=$(current_readers | wc -l | tr -d ' ')
  step "Reader endpoint, 10 new connections ($READERS reader(s) in the cluster)"
  spread "$CLUSTER_READER" 10
  if (( READERS >= 2 )); then
    (( SPREAD_DISTINCT >= 2 )) && ok "Connections were spread over $SPREAD_DISTINCT readers (DNS round-robin, 1s TTL)" \
                               || warn "All landed on one reader this time; DNS caching on your machine can do this. Re-run."
  else
    ok "Only one reader, so everything lands on it. Add readers (11c-serverless-reader.sh add, or auto scaling) and re-run."
  fi
  info "It balances CONNECTIONS, not queries: a long-lived connection pool stays where it first landed."
  step "Writer endpoint always lands on the writer"
  spread "$CLUSTER_WRITER" 3
  lab_next "bash $0 create    # custom endpoint for reporting traffic"
  lab_success "endpoint behaviour shown" ;;
create)
  if [[ "$(ep_status)" != not-found ]]; then ok "Custom endpoint $CUSTOM_ENDPOINT_ID already exists"
  else
    MEMBER=$(cq 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`false`] | sort_by(@,&PromotionTier)[-1].DBInstanceIdentifier')
    [[ -n "$MEMBER" && "$MEMBER" != None ]] || die "No reader to put behind the custom endpoint"
    info "Custom endpoint $CUSTOM_ENDPOINT_ID -> only reader $MEMBER (e.g. send BI/reporting there, keep other readers for the app)."
    confirm "Create custom endpoint"
    aws rds create-db-cluster-endpoint --db-cluster-identifier "$CLUSTER_ID" --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" \
      --endpoint-type READER --static-members "$MEMBER" --region "$AWS_REGION" >/dev/null
    ok "Requested"
  fi
  poll "custom endpoint" "available" 600 ep_status || die "Custom endpoint not available"
  EP=$(aws rds describe-db-cluster-endpoints --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION" --query 'DBClusterEndpoints[0].Endpoint' --output text)
  MEMBERS=$(aws rds describe-db-cluster-endpoints --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION" --query 'DBClusterEndpoints[0].StaticMembers' --output text)
  step "Verify"
  if can_sql; then
    EXPECT=$(iq 'DBInstances[0].Endpoint.Address' "$MEMBERS")
    spread "$EP" 5
    GOT_HOST=$(sql "$EP" "select inet_server_addr()"); EXP_IP=$(sql "$EXPECT" "select inet_server_addr()")
    [[ "$GOT_HOST" == "$EXP_IP" && $SPREAD_DISTINCT == 1 ]] && ok "Every connection landed on $MEMBERS ($EXP_IP)" || warn "Landed on $GOT_HOST, expected $EXP_IP"
  fi
  step "Connect (copy-paste)"
  show_endpoint "Custom endpoint ($MEMBERS):" "$EP"; password_hint
  lab_next "bash 03-status.sh     # lists custom endpoints" "bash $0 delete"
  lab_success "custom endpoint $CUSTOM_ENDPOINT_ID routes only to $MEMBERS" ;;
delete)
  [[ "$(ep_status)" == not-found ]] && { ok "Nothing to delete"; lab_success "no custom endpoint"; exit 0; }
  aws rds delete-db-cluster-endpoint --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION" >/dev/null
  poll "custom endpoint" "not-found" 600 ep_status || true
  lab_success "custom endpoint deleted" ;;
*) die "Usage: bash $0 {demo|create|delete}" ;;
esac
