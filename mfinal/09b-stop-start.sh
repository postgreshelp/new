#!/usr/bin/env bash
# Stop the cluster overnight (compute billing stops), start it next morning, verify it answers.
#   bash 09b-stop-start.sh stop | start | status
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-status}"
lab_init "Stop / start cluster: $ACTION"
cluster_exists || die "Cluster $CLUSTER_ID not found"
STATUS=$(cluster_status)

case "$ACTION" in
status)
  ok "Cluster $CLUSTER_ID is $STATUS"
  lab_next "bash $0 stop" "bash $0 start"
  lab_success "status shown" ;;
stop)
  [[ "$STATUS" == stopped ]] && { ok "Already stopped"; lab_next "bash $0 start"; lab_success "nothing to do"; exit 0; }
  [[ "$STATUS" == available ]] || die "Cluster must be available to stop (now: $STATUS)"
  BG=$(aws rds describe-blue-green-deployments --region "$AWS_REGION" --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].Status | [0]" --output text 2>/dev/null || true)
  [[ -z "$BG" || "$BG" == None ]] || die "A Blue/Green deployment exists ($BG). AWS can't stop a cluster in a Blue/Green deployment: bash 15-bluegreen.sh cleanup"
  info "Stops all instances of $CLUSTER_ID. Storage and backups keep billing; AWS restarts it automatically after 7 days."
  [[ -n "${PROXY_ENDPOINT:-}" ]] && info "RDS Proxy keeps billing while the cluster is stopped. Client EC2: stop it in the EC2 console if you like."
  confirm "Stop $CLUSTER_ID"
  aws rds stop-db-cluster --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" >/dev/null
  ok "Stop requested"
  poll "cluster" "stopped" 1800 cluster_status || die "Cluster did not reach 'stopped'"
  lab_next "bash $0 start      # tomorrow morning (~5-10 min)"
  lab_success "cluster stopped — compute billing paused" ;;
start)
  [[ "$STATUS" == available ]] && { ok "Already running"; db_check "Writer endpoint" "$(cq 'DBClusters[0].Endpoint')" || true; lab_next "bash 03-status.sh"; lab_success "nothing to do"; exit 0; }
  [[ "$STATUS" == stopped ]] || die "Cluster must be stopped to start (now: $STATUS)"
  aws rds start-db-cluster --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" >/dev/null
  ok "Start requested"
  poll "cluster" "available" 1800 cluster_status || die "Cluster did not become available"
  for i in $(cluster_instances); do poll "instance $i" "available" 900 instance_status "$i" || true; done
  step "Verify"
  db_check "Writer endpoint" "$(cq 'DBClusters[0].Endpoint')" || warn "Not answering yet; try again in a minute: bash 03-status.sh"
  lab_next "bash 03-status.sh"
  lab_success "cluster is running again" ;;
*) die "Usage: bash $0 {stop|start|status}" ;;
esac
