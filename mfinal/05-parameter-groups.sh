#!/usr/bin/env bash
# Read-only: cluster vs instance parameter groups, pending-reboot status, live values via SHOW.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Parameter groups (read-only)"
need_endpoints

PG=$(cq 'DBClusters[0].DBClusterParameterGroup')
step "Cluster parameter group: $PG (applies to every instance)"
info "Parameters you changed (Source=user):"
aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$PG" --source user --region "$AWS_REGION" \
  --query 'Parameters[].{Name:ParameterName,Value:ParameterValue,ApplyType:ApplyType,Method:ApplyMethod}' --output table
info "A few interesting defaults:"
aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$PG" --region "$AWS_REGION" \
  --query "Parameters[?contains(['rds.logical_replication','max_replication_slots','log_min_duration_statement','shared_preload_libraries'], ParameterName)].{Name:ParameterName,Value:ParameterValue,ApplyType:ApplyType}" --output table

step "Instance parameter groups (per instance) and apply status"
printf '  %-28s %-34s %s\n' INSTANCE "DB PARAMETER GROUP" "STATUS (cluster PG / instance PG)"
while IFS= read -r i; do
  [[ -n "$i" ]] || continue
  ipg=$(iq 'DBInstances[0].DBParameterGroups[0].[DBParameterGroupName,ParameterApplyStatus]' "$i" | tr '\t' ' ')
  cstat=$(cq "DBClusters[0].DBClusterMembers[?DBInstanceIdentifier=='$i'].DBClusterParameterGroupStatus | [0]")
  printf '  %-28s %-34s %s / %s\n' "$i" "${ipg% *}" "$cstat" "${ipg##* }"
done < <(cluster_instances)
info "in-sync = applied. pending-reboot = a static change is waiting for a reboot of that instance."

step "Live values (SHOW)"
if can_sql; then
  for p in rds.logical_replication max_connections log_min_duration_statement shared_buffers work_mem; do
    printf '  %-28s %s\n' "$p" "$(sql "$CLUSTER_WRITER" "show $p" 2>/dev/null || echo '?')"
  done
else
  warn "Set PGPASSWORD in env.sh to see live values, or run in psql: SHOW max_connections;"
  psql_cmd "$CLUSTER_WRITER"
fi
info "Teaching: dynamic params apply at once; static ones (ApplyType=static) need a reboot."
info "Aurora has NO postgresql.conf — parameter groups replace it; ALTER SYSTEM is not allowed."

lab_next "bash 05b-param-change.sh      # make a dynamic and a static change"
lab_success "parameter groups shown"
