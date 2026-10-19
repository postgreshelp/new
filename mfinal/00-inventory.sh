#!/usr/bin/env bash
# Read-only: everything this lab can create, whether it exists now, and whether it bills while it exists.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Lab inventory (read-only)"

BILLABLE=0
row() {  # row <billable yes/no> <type> <name> <state>
  local mark="  -  "
  if [[ -n "$4" && "$4" != None && "$4" != not-found ]]; then
    mark="${C_G}  ✓  ${C_0}"; [[ "$1" == yes ]] && { mark="${C_Y}  \$  ${C_0}"; BILLABLE=$((BILLABLE+1)); }
  fi
  printf '%s %-22s %-42s %s\n' "$mark" "$2" "$3" "${4:-absent}"
}
printf '\n  ($ = exists and billable, ✓ = exists, - = absent)\n\n'

step "Network"
row no "VPC"            "${VPC_ID:-<not created>}"   "$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID:-x}" --region "$AWS_REGION" --query 'Vpcs[0].State' --output text 2>/dev/null || true)"
row no "Aurora SG"      "${SG_ID:-<not created>}"    "$(aws ec2 describe-security-groups --group-ids "${SG_ID:-x}" --region "$AWS_REGION" --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null || true)"
row no "DB subnet group" "$DB_SUBNET_GROUP"          "$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" --query 'DBSubnetGroups[0].SubnetGroupStatus' --output text 2>/dev/null || true)"
row no "S3 VPC endpoint" "${S3_ENDPOINT_ID:-<none>}" "$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${S3_ENDPOINT_ID:-x}" --region "$AWS_REGION" --query 'VpcEndpoints[0].State' --output text 2>/dev/null || true)"

step "Clusters and instances"
for c in "$CLUSTER_ID" "${CLUSTER_ID}-old1" "$CLONE_ID" "$PITR_ID"; do
  row yes "Cluster" "$c" "$(cluster_status "$c" | sed 's/^not-found$//')"
  while IFS= read -r i; do
    [[ -n "$i" ]] || continue
    row yes "  instance" "$i ($(iq 'DBInstances[0].DBInstanceClass' "$i"))" "$(instance_status "$i")"
  done < <(cluster_instances "$c")
done
GREEN=$(aws rds describe-db-clusters --region "$AWS_REGION" --query "DBClusters[?contains(DBClusterIdentifier, '${CLUSTER_ID}-green-')].DBClusterIdentifier" --output text 2>/dev/null || true)
for g in $GREEN; do row yes "Cluster (green)" "$g" "$(cluster_status "$g")"; done
row no "Custom endpoint" "$CUSTOM_ENDPOINT_ID" "$(aws rds describe-db-cluster-endpoints --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION" --query 'DBClusterEndpoints[0].Status' --output text 2>/dev/null || true)"
row no "Cluster param group" "$CLUSTER_PG" "$(aws rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" --query 'DBClusterParameterGroups[0].DBParameterGroupFamily' --output text 2>/dev/null || true)"
row no "Instance param group" "$INSTANCE_PG" "$(aws rds describe-db-parameter-groups --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION" --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text 2>/dev/null || true)"
SNAPS=$(aws rds describe-db-cluster-snapshots --snapshot-type manual --region "$AWS_REGION" --query "DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier,'mybank-manual-')].DBClusterSnapshotIdentifier" --output text 2>/dev/null || true)
row yes "Manual snapshots" "mybank-manual-*" "$( [[ -n "$SNAPS" ]] && echo "$(wc -w <<<"$SNAPS") snapshot(s)" )"

step "Blue/Green"
BG=$(aws rds describe-blue-green-deployments --region "$AWS_REGION" --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].[BlueGreenDeploymentIdentifier,Status]" --output text 2>/dev/null || true)
row no "Blue/Green deployment" "$BG_NAME ${BG%%[[:space:]]*}" "${BG##*[[:space:]]}"

step "Proxy, client, scaling"
row yes "RDS Proxy" "$PROXY_NAME" "$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" --query 'DBProxies[0].Status' --output text 2>/dev/null || true)"
row no "Proxy secret" "$PROXY_SECRET_NAME" "$(aws secretsmanager describe-secret --secret-id "$PROXY_SECRET_NAME" --region "$AWS_REGION" --query 'Name' --output text 2>/dev/null || true)"
CLIENT_STATE=$(aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=tag:Name,Values=$CLIENT_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' --output text 2>/dev/null || true)
[[ "$CLIENT_STATE" == None* ]] && CLIENT_STATE=""
row yes "Client EC2" "$CLIENT_NAME ${CLIENT_STATE%%[[:space:]]*}" "$(awk '{print $2, $3}' <<<"$CLIENT_STATE" | sed 's/^ *$//')"
row no "Reader auto scaling" "cluster:$CLUSTER_ID" "$(aws application-autoscaling describe-scaling-policies --service-namespace rds --resource-id "cluster:$CLUSTER_ID" --region "$AWS_REGION" --query 'ScalingPolicies[0].PolicyName' --output text 2>/dev/null || true)"

step "IAM and S3"
for r in "$PROXY_ROLE_NAME" "$S3_IMPORT_ROLE_NAME" "$S3_EXPORT_ROLE_NAME"; do
  row no "IAM role" "$r" "$(aws iam get-role --role-name "$r" --query 'Role.RoleName' --output text 2>/dev/null | sed 's/..*/exists/' || true)"
done
row no "S3 bucket" "${S3_DATA_BUCKET:-<unset>}" "$(aws s3api head-bucket --bucket "${S3_DATA_BUCKET:-x}" --region "$AWS_REGION" >/dev/null 2>&1 && echo exists || true)"

echo
if (( BILLABLE > 0 )); then
  warn "$BILLABLE billable item(s) exist. Stop overnight: bash 09b-stop-start.sh stop   | remove all: bash 90-teardown.sh"
else
  ok "Nothing billable found"
fi
lab_success "inventory complete, nothing changed"
