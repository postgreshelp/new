#!/usr/bin/env bash
# Read-only: cluster health, who is writer, every endpoint with a copy-paste psql command, live connection test.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Cluster status and endpoints (read-only)"

cluster_exists || die "Cluster $CLUSTER_ID not found. Create it: bash 02-create-cluster.sh"

step "Cluster"
aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" \
  --query 'DBClusters[0].{Status:Status,Version:EngineVersion,ParamGroup:DBClusterParameterGroup,DeletionProtection:DeletionProtection,BackupDays:BackupRetentionPeriod,Storage:StorageType}' --output table
STATUS=$(cluster_status)
[[ "$STATUS" == available ]] && ok "Cluster is available" || warn "Cluster status is '$STATUS' (not available yet)"

step "Members (who is writer?)"
printf '  %-28s %-7s %-6s %-12s %-16s %s\n' INSTANCE ROLE TIER AZ CLASS STATUS
WRITER=$(current_writer)
while IFS= read -r i; do
  [[ -n "$i" ]] || continue
  read -r az class st tier < <(iq 'DBInstances[0].[AvailabilityZone,DBInstanceClass,DBInstanceStatus,PromotionTier]' "$i")
  role=reader; [[ "$i" == "$WRITER" ]] && role=WRITER
  printf '  %-28s %-7s %-6s %-12s %-16s %s\n' "$i" "$role" "$tier" "$az" "$class" "$st"
done < <(cluster_instances)
info "Failover goes to the reader with the lowest promotion tier."

step "Endpoints (copy-paste)"
show_endpoint "Writer (cluster endpoint):" "$(cq 'DBClusters[0].Endpoint')"
show_endpoint "Readers (reader endpoint):" "$(cq 'DBClusters[0].ReaderEndpoint')"
while IFS= read -r i; do
  [[ -n "$i" ]] || continue
  show_endpoint "Instance $i:" "$(iq 'DBInstances[0].Endpoint.Address' "$i")"
done < <(cluster_instances)
CUSTOM=$(aws rds describe-db-cluster-endpoints --db-cluster-identifier "$CLUSTER_ID" --region "$AWS_REGION" \
  --query "DBClusterEndpoints[?EndpointType=='CUSTOM'].Endpoint" --output text 2>/dev/null || true)
for e in $CUSTOM; do show_endpoint "Custom endpoint:" "$e"; done
[[ -n "${PROXY_ENDPOINT:-}" ]] && { show_endpoint "RDS Proxy (from client EC2 only):" "$PROXY_ENDPOINT"; }
password_hint

step "Live check"
db_check "Writer endpoint" "$(cq 'DBClusters[0].Endpoint')" || true
db_check "Reader endpoint" "$(cq 'DBClusters[0].ReaderEndpoint')" || true

lab_next "bash 04-failover-demo.sh      # failover" "bash 03b-endpoints.sh create   # custom endpoint"
lab_success "status shown (cluster: $STATUS, writer: $WRITER)"
