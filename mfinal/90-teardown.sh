#!/usr/bin/env bash
# Delete EVERYTHING this lab can create, in dependency order, then show what is left.
#   bash 90-teardown.sh              # shows the inventory, asks once, deletes
#   bash 90-teardown.sh --keep-s3    # keep the S3 bucket and its objects
#   bash 90-teardown.sh --keep-network   # keep VPC/subnets/SG (rebuild the cluster faster next time)
# Safe to re-run: anything already gone is skipped. If the VPC can't be deleted yet (ENIs still releasing), re-run in 5 min.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
KEEP_S3=0; KEEP_NET=0
for a in "$@"; do case "$a" in --keep-s3) KEEP_S3=1;; --keep-network) KEEP_NET=1;; *) echo "Unknown option $a"; exit 2;; esac; done
lab_init "Teardown"

bash ./00-inventory.sh </dev/null 2>/dev/null | sed -n '/==> /,/RESULT/p' | grep -v RESULT || true
echo
warn "Deletes all lab clusters WITHOUT final snapshots, manual mybank-manual-* snapshots, proxy, client EC2, IAM roles, secret,"
warn "parameter groups, log groups$( ((KEEP_S3)) || echo ', S3 bucket')$( ((KEEP_NET)) || echo ', and the whole network') in $AWS_REGION / account $AWS_ACCOUNT_ID."
if [[ "${LAB_YES:-0}" != 1 ]]; then
  read -r -p "  Type DELETE to continue: " A; [[ "$A" == DELETE ]] || lab_cancel
fi

delete_cluster() {  # delete_cluster <id>
  local c="$1" i
  cluster_exists "$c" || return 0
  step "Cluster $c"
  aws rds modify-db-cluster --db-cluster-identifier "$c" --no-deletion-protection --apply-immediately --region "$AWS_REGION" >/dev/null 2>&1 \
    && ok "deletion protection off" || true
  for i in $(cluster_instances "$c"); do try "delete instance $i" aws rds delete-db-instance --db-instance-identifier "$i" --skip-final-snapshot --region "$AWS_REGION"; done
  for i in $(cluster_instances "$c"); do aws rds wait db-instance-deleted --db-instance-identifier "$i" --region "$AWS_REGION" 2>/dev/null || true; done
  try "delete cluster $c (no final snapshot)" aws rds delete-db-cluster --db-cluster-identifier "$c" --skip-final-snapshot --region "$AWS_REGION"
}
wait_cluster_gone() { local c; for c in "$@"; do cluster_exists "$c" && { poll "cluster $c" "not-found" 1800 cluster_status "$c" || true; }; done; return 0; }

# 1. Blue/Green
BG_ID=$(aws rds describe-blue-green-deployments --region "$AWS_REGION" --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].BlueGreenDeploymentIdentifier | [0]" --output text 2>/dev/null | sed 's/^None$//')
if [[ -n "$BG_ID" ]]; then
  step "Blue/Green deployment"
  ST=$(aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$BG_ID" --region "$AWS_REGION" --query 'BlueGreenDeployments[0].Status' --output text)
  if [[ "$ST" == SWITCHOVER_COMPLETED ]]; then try "delete deployment (after switchover)" aws rds delete-blue-green-deployment --blue-green-deployment-identifier "$BG_ID" --no-delete-target --region "$AWS_REGION"
  else try "delete deployment + green ($ST)" aws rds delete-blue-green-deployment --blue-green-deployment-identifier "$BG_ID" --delete-target --region "$AWS_REGION"; fi
  bgs() { aws rds describe-blue-green-deployments --blue-green-deployment-identifier "$BG_ID" --region "$AWS_REGION" --query 'BlueGreenDeployments[0].Status' --output text 2>/dev/null || echo gone; }
  poll "deployment" "gone" 1800 bgs || warn "Deployment still listed"
fi

# 2. Things that sit in front of / attach to the cluster
step "Auto scaling, custom endpoint, proxy, client EC2"
AS=(--service-namespace rds --scalable-dimension rds:cluster:ReadReplicaCount --resource-id "cluster:$CLUSTER_ID" --region "$AWS_REGION")
if [[ "$(aws application-autoscaling describe-scalable-targets --service-namespace rds --resource-ids "cluster:$CLUSTER_ID" --region "$AWS_REGION" --query 'length(ScalableTargets)' --output text 2>/dev/null || echo 0)" != 0 ]]; then
  try "delete scaling policy" aws application-autoscaling delete-scaling-policy "${AS[@]}" --policy-name "${CLUSTER_ID}-reader-cpu-target"
  try "deregister scalable target" aws application-autoscaling deregister-scalable-target "${AS[@]}"
fi
aws rds describe-db-cluster-endpoints --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION" >/dev/null 2>&1 \
  && try "delete custom endpoint $CUSTOM_ENDPOINT_ID" aws rds delete-db-cluster-endpoint --db-cluster-endpoint-identifier "$CUSTOM_ENDPOINT_ID" --region "$AWS_REGION"
if aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  try "delete proxy $PROXY_NAME" aws rds delete-db-proxy --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION"
  pst() { aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" --query 'DBProxies[0].Status' --output text 2>/dev/null || echo gone; }
  poll "proxy" "gone" 1200 pst || warn "Proxy still deleting"
fi
LAB_YES=1 bash ./10a-client-ec2.sh delete 2>&1 | grep -E '\[(OK|WARN|ERROR)\]' || true

# 3. Clusters (instances first, then each cluster; then wait for all)
for c in "$CLONE_ID" "$PITR_ID" "${CLUSTER_ID}-old1" "$CLUSTER_ID" \
         $(aws rds describe-db-clusters --region "$AWS_REGION" --query "DBClusters[?starts_with(DBClusterIdentifier,'${CLUSTER_ID}-green-')].DBClusterIdentifier" --output text 2>/dev/null); do
  delete_cluster "$c"
done
step "Waiting for clusters to disappear (5-15 min)"
wait_cluster_gone "$CLONE_ID" "$PITR_ID" "${CLUSTER_ID}-old1" "$CLUSTER_ID"
cluster_exists "$CLUSTER_ID" && die "Cluster $CLUSTER_ID still exists; re-run teardown in a few minutes"
ok "All lab clusters gone"

# 4. Snapshots, parameter groups, log groups
step "Snapshots, parameter groups, logs"
for s in $(aws rds describe-db-cluster-snapshots --snapshot-type manual --region "$AWS_REGION" \
            --query "DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier,'mybank-manual-')].DBClusterSnapshotIdentifier" --output text 2>/dev/null); do
  try "delete snapshot $s" aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "$s" --region "$AWS_REGION"
done
aws rds describe-db-parameter-groups --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION" >/dev/null 2>&1 \
  && try "delete instance PG $INSTANCE_PG" aws rds delete-db-parameter-group --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION"
aws rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" >/dev/null 2>&1 \
  && try "delete cluster PG $CLUSTER_PG" aws rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION"
for c in "$CLUSTER_ID" "${CLUSTER_ID}-old1" "$CLONE_ID" "$PITR_ID"; do
  aws logs delete-log-group --log-group-name "/aws/rds/cluster/$c/postgresql" --region "$AWS_REGION" >/dev/null 2>&1 && ok "deleted log group for $c" || true
done

# 5. IAM roles (inline + any attached managed policies, incl. ones from older script versions) and the secret
step "IAM roles and secret"
for r in "$PROXY_ROLE_NAME" "$S3_IMPORT_ROLE_NAME" "$S3_EXPORT_ROLE_NAME"; do
  aws iam get-role --role-name "$r" >/dev/null 2>&1 || continue
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text); do aws iam delete-role-policy --role-name "$r" --policy-name "$p"; done
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p"
    [[ "$p" == *":policy/MyBank"* ]] && aws iam delete-policy --policy-arn "$p" >/dev/null 2>&1 || true
  done
  try "delete role $r" aws iam delete-role --role-name "$r"
done
aws secretsmanager describe-secret --secret-id "$PROXY_SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
  && try "delete secret $PROXY_SECRET_NAME (immediately, so the lab can be rebuilt)" aws secretsmanager delete-secret --secret-id "$PROXY_SECRET_NAME" --force-delete-without-recovery --region "$AWS_REGION"

# 6. S3
if (( ! KEEP_S3 )) && [[ -n "${S3_DATA_BUCKET:-}" ]] && aws s3api head-bucket --bucket "$S3_DATA_BUCKET" >/dev/null 2>&1; then
  step "S3 bucket $S3_DATA_BUCKET"
  try "empty bucket" aws s3 rm "s3://$S3_DATA_BUCKET" --recursive --region "$AWS_REGION" --only-show-errors
  try "delete bucket" aws s3api delete-bucket --bucket "$S3_DATA_BUCKET" --region "$AWS_REGION"
fi

# 7. Network
if (( ! KEEP_NET )) && [[ -n "${VPC_ID:-}" ]] && aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
  step "Network $VPC_ID"
  P_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$PROXY_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | sed 's/^None$//')
  for sg in "${SG_ID:-}" "$P_SG"; do   # Aurora SG first: it holds the rule that references the proxy SG
    [[ -n "$sg" ]] || continue
    for ((t = 0; t < 12; t++)); do aws ec2 delete-security-group --group-id "$sg" --region "$AWS_REGION" >/dev/null 2>&1 && break; sleep 10; done
    aws ec2 describe-security-groups --group-ids "$sg" --region "$AWS_REGION" >/dev/null 2>&1 && warn "SG $sg still in use (ENIs releasing?)" || ok "deleted SG $sg"
  done
  aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" >/dev/null 2>&1 \
    && try "delete DB subnet group" aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION"
  for ep in $(aws ec2 describe-vpc-endpoints --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    try "delete VPC endpoint $ep" aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ep" --region "$AWS_REGION"
  done
  for sid in "${SUBNET1_ID:-}" "${SUBNET2_ID:-}" "${SUBNET3_ID:-}"; do
    [[ -n "$sid" ]] || continue
    for ((t = 0; t < 12; t++)); do aws ec2 delete-subnet --subnet-id "$sid" --region "$AWS_REGION" >/dev/null 2>&1 && break; sleep 10; done
    aws ec2 describe-subnets --subnet-ids "$sid" --region "$AWS_REGION" >/dev/null 2>&1 && warn "subnet $sid still in use" || ok "deleted subnet $sid"
  done
  [[ -n "${RT_ID:-}" ]] && try "delete route table $RT_ID" aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$AWS_REGION"
  if [[ -n "${IGW_ID:-}" ]]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
    try "delete IGW $IGW_ID" aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION"
  fi
  if aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1; then ok "deleted VPC $VPC_ID"; NET_GONE=1
  else warn "VPC $VPC_ID not deleted yet (something still inside). Re-run: bash 90-teardown.sh"; NET_GONE=0; fi
else
  NET_GONE=$(( KEEP_NET ? 0 : 1 ))
fi

# 8. Local state files
step "Local state files"
rm -f endpoints.env proxy.env client.env s3-resources.env "${CLIENT_KEY_NAME}.pem"
(( NET_GONE )) && rm -f B02-network.env
ok "Removed generated *.env files$( ((NET_GONE)) || echo ' (kept B02-network.env: network still exists)')"

step "What is left"
bash ./00-inventory.sh </dev/null 2>/dev/null | sed -n '/==> /,/RESULT/p' | grep -E '\$|✓|WARN|OK' || true
lab_next "bash 00-inventory.sh     # double-check" "bash 01-create-network.sh   # rebuild from scratch"
lab_success "teardown finished — review any [WARN] lines above"
