#!/usr/bin/env bash
# Add an Aurora Serverless v2 reader (db.serverless) to the provisioned cluster ("mixed" cluster).
#   bash 11c-serverless-reader.sh add      # set ACU range, add reader, show its capacity
#   bash 11c-serverless-reader.sh watch    # print ServerlessDatabaseCapacity (ACU) every 30s (Ctrl-C to stop)
#   bash 11c-serverless-reader.sh remove
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-add}"
lab_init "Serverless v2 reader: $ACTION"
need_endpoints

acu() {  # latest ServerlessDatabaseCapacity of the serverless reader
  local s e
  read -r s e < <(python3 -c 'import datetime as d; n=d.datetime.now(d.timezone.utc); f="%Y-%m-%dT%H:%M:%SZ"; print((n-d.timedelta(minutes=10)).strftime(f), n.strftime(f))')
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ServerlessDatabaseCapacity --dimensions Name=DBInstanceIdentifier,Value="$SERVERLESS_READER" \
    --start-time "$s" --end-time "$e" --period 60 --statistics Average --region "$AWS_REGION" \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Average' --output text 2>/dev/null | sed 's/None/-/'
}

case "$ACTION" in
add)
  [[ "$(cluster_status)" == available ]] || die "Cluster must be available"
  if [[ "$(instance_status "$SERVERLESS_READER")" != not-found ]]; then ok "$SERVERLESS_READER already exists"
  else
    info "Cluster capacity range: $SV2_MIN_ACU - $SV2_MAX_ACU ACU (1 ACU ~ 2 GiB RAM). Billed per ACU-second."
    info "Promotion tier 15 = last choice for failover, so the provisioned reader stays the failover target."
    confirm "Add serverless reader $SERVERLESS_READER"
    aws rds modify-db-cluster --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" --apply-immediately \
      --serverless-v2-scaling-configuration "MinCapacity=$SV2_MIN_ACU,MaxCapacity=$SV2_MAX_ACU" >/dev/null
    ok "Cluster serverless v2 range set"
    poll "cluster" "available" 600 cluster_status || true
    aws rds create-db-instance --db-instance-identifier "$SERVERLESS_READER" --db-cluster-identifier "$CLUSTER_ID" --engine aurora-postgresql \
      --db-instance-class db.serverless --promotion-tier 15 "$(access_flag)" --region "$AWS_REGION" \
      --tags Key=Project,Value=MyBankAuroraWorkshop Key=Role,Value=serverless-reader >/dev/null
    ok "db.serverless instance requested"
  fi
  poll "$SERVERLESS_READER" "available" 1800 instance_status "$SERVERLESS_READER" || die "Serverless reader did not become available"
  EP=$(iq 'DBInstances[0].Endpoint.Address' "$SERVERLESS_READER")
  step "Verify"
  read -r MIN MAX < <(cq 'DBClusters[0].ServerlessV2ScalingConfiguration.[MinCapacity,MaxCapacity]')
  ok "Cluster ACU range: $MIN - $MAX"
  db_check "Serverless reader (direct)" "$EP" || true
  info "Current capacity: $(acu) ACU (metric appears 1-2 min after start)"
  info "It also joined the reader endpoint: bash 03b-endpoints.sh demo"
  step "Make it scale (copy-paste on the client EC2, or any machine with pgbench)"
  cmd "pgbench \"$(conninfo "$CLUSTER_WRITER")\" -i -s 5   # once, on the WRITER (readers are read-only)"
  cmd "pgbench \"$(conninfo "$EP")\" -S -c 16 -j 4 -T 300 -n -P 30"
  cmd "bash 11c-serverless-reader.sh watch          # in another terminal, on the laptop"
  show_endpoint "Serverless reader:" "$EP"; password_hint
  lab_next "bash $0 watch" "bash $0 remove"
  lab_success "serverless v2 reader $SERVERLESS_READER is in the cluster" ;;
watch)
  info "ACU of $SERVERLESS_READER every 30s (min $SV2_MIN_ACU, max $SV2_MAX_ACU). Ctrl-C to stop."
  trap 'LAB_DONE=1; echo; exit 0' INT
  while true; do printf '          [%s] %s ACU\n' "$(date +%H:%M:%S)" "$(acu)"; sleep 30; done ;;
remove)
  [[ "$(instance_status "$SERVERLESS_READER")" == not-found ]] && { ok "Not present"; lab_success "nothing to remove"; exit 0; }
  confirm "Delete $SERVERLESS_READER"
  aws rds delete-db-instance --db-instance-identifier "$SERVERLESS_READER" --region "$AWS_REGION" >/dev/null
  poll "$SERVERLESS_READER" "not-found" 1800 instance_status "$SERVERLESS_READER" || true
  lab_success "serverless reader removed" ;;
*) die "Usage: bash $0 {add|watch|remove}" ;;
esac
