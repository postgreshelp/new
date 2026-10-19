#!/usr/bin/env bash
# RDS Proxy for the lab cluster.
#   bash 10-rds-proxy.sh          # secret + IAM role + proxy SG + proxy; register cluster; WAIT for healthy target; save proxy.env
#   bash 10-rds-proxy.sh status   # proxy + target health
# The proxy endpoint is PRIVATE (VPC-only): test it from the client EC2 (10a), not from your laptop.
# Register the proxy BEFORE creating Blue/Green: AWS blocks registration while a Blue/Green deployment exists.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-create}"
lab_init "RDS Proxy: $ACTION"
AURORA_SG_ID="${SG_ID:-?}"; PROXY_SG_ID="${PROXY_SG_ID:-?}"

show_status() {
  aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" \
    --query 'DBProxies[0].{Name:DBProxyName,Status:Status,Endpoint:Endpoint,RequireTLS:RequireTLS,IdleTimeout:IdleClientTimeout}' --output table
  aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" --target-group-name default --region "$AWS_REGION" \
    --query 'Targets[*].{Target:RdsResourceId,Type:Type,Role:Role,Health:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' --output table
}
writer_target_health() {  # prints "STATE REASON"
  local out
  out=$(aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" --target-group-name default --region "$AWS_REGION" \
        --query "Targets[?Type=='RDS_INSTANCE' && Role=='READ_WRITE'] | [0].[TargetHealth.State, TargetHealth.Reason]" --output text 2>/dev/null || true)
  [[ -z "$out" || "$out" == None* ]] && out="REGISTERING None"
  echo "$out" | tr '\t' ' '
}
hint_for_reason() {
  case "$1" in
    PENDING_PROXY_CAPACITY|None|"") info "-> normal while the proxy warms up; keep waiting" ;;
    AUTH_FAILURE)
      info "-> the proxy reached the DB but LOGIN failed: the secret's password is wrong (or the role can't read the secret). Fix:"
      cmd "aws secretsmanager put-secret-value --secret-id $PROXY_SECRET_NAME --region $AWS_REGION --secret-string '{\"username\":\"$PGUSER\",\"password\":\"<master password>\"}'"
      info "   the proxy re-reads it within a few minutes; this loop keeps waiting" ;;
    CONNECTION_FAILED|UNREACHABLE)
      info "-> the proxy can't open tcp/5432 to the instance: Aurora SG $AURORA_SG_ID needs 5432 from proxy SG $PROXY_SG_ID (this script adds it)" ;;
    *) info "-> transient during failover/reboot, or see Description in: bash $0 status" ;;
  esac
}

if [[ "$ACTION" == status ]]; then
  show_status
  read -r ST RS < <(writer_target_health)
  [[ "$ST" == AVAILABLE ]] && ok "Writer target AVAILABLE" || { warn "Writer target $ST ($RS)"; hint_for_reason "$RS"; }
  [[ -n "${PROXY_ENDPOINT:-}" ]] && { step "From the client EC2 (copy-paste)"; psql_cmd "$PROXY_ENDPOINT"; }
  lab_success "proxy status shown"; exit 0
fi
[[ "$ACTION" == create ]] || die "Usage: bash $0 [create|status]"

step "Pre-checks"
[[ "$(cluster_status)" == available ]] || die "Cluster must be available (now: $(cluster_status))"
BG=$(aws rds describe-blue-green-deployments --region "$AWS_REGION" --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].Status | [0]" --output text 2>/dev/null || true)
[[ -z "$BG" || "$BG" == None ]] || warn "Blue/Green deployment exists ($BG): registering the cluster with a NEW proxy will be blocked by AWS"
DB_SUBNET_GROUP=$(cq 'DBClusters[0].DBSubnetGroup'); AURORA_SG_ID=$(cq 'DBClusters[0].VpcSecurityGroups[0].VpcSecurityGroupId')
VPC_ID=$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" --query 'DBSubnetGroups[0].VpcId' --output text)
mapfile -t SUBNETS < <(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" \
  --query 'DBSubnetGroups[0].Subnets[].SubnetIdentifier' --output text | tr '\t' '\n')
((${#SUBNETS[@]} >= 2)) || die "RDS Proxy needs 2+ subnets in different AZs; $DB_SUBNET_GROUP has ${#SUBNETS[@]}"
ok "Cluster available; VPC $VPC_ID; ${#SUBNETS[@]} subnets; Aurora SG $AURORA_SG_ID"
info "Creates (or reuses): secret $PROXY_SECRET_NAME, IAM role $PROXY_ROLE_NAME, SG $PROXY_SG_NAME, proxy $PROXY_NAME (billable). ~10 min."
confirm "Set up RDS Proxy"

TMP_DIR=$(mktemp -d); on_cleanup "rm -rf '$TMP_DIR'"

step "1. Secret (the login the proxy uses towards the database)"
SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$PROXY_SECRET_NAME" --region "$AWS_REGION" --query ARN --output text 2>/dev/null || true)
if [[ -n "$SECRET_ARN" && "$SECRET_ARN" != None ]]; then
  DELETED=$(aws secretsmanager describe-secret --secret-id "$SECRET_ARN" --region "$AWS_REGION" --query DeletedDate --output text 2>/dev/null || true)
  if [[ -n "$DELETED" && "$DELETED" != None ]]; then aws secretsmanager restore-secret --secret-id "$SECRET_ARN" --region "$AWS_REGION" >/dev/null; ok "Restored secret that was pending deletion"; fi
  if [[ -n "${PGPASSWORD:-}" ]]; then
    printf '{"username":"%s","password":"%s"}' "$PGUSER" "$PGPASSWORD" > "$TMP_DIR/s.json"
    aws secretsmanager put-secret-value --secret-id "$SECRET_ARN" --secret-string "file://$TMP_DIR/s.json" --region "$AWS_REGION" >/dev/null
    ok "Reusing $PROXY_SECRET_NAME; refreshed it from PGUSER/PGPASSWORD in env.sh"
  else
    ok "Reusing $PROXY_SECRET_NAME (if the target shows AUTH_FAILURE, its password is wrong)"
  fi
else
  PW="${PGPASSWORD:-}"
  [[ -n "$PW" ]] || { read -r -s -p "  Master password for $PGUSER (stored in the secret): " PW; echo; }
  [[ -n "$PW" ]] || die "Password cannot be empty"
  printf '{"username":"%s","password":"%s"}' "$PGUSER" "$PW" > "$TMP_DIR/s.json"; unset PW
  SECRET_ARN=$(aws secretsmanager create-secret --name "$PROXY_SECRET_NAME" --description "MyBank workshop RDS Proxy credentials" \
    --secret-string "file://$TMP_DIR/s.json" --tags Key=Project,Value=MyBankAuroraWorkshop --region "$AWS_REGION" --query ARN --output text)
  ok "Created secret $PROXY_SECRET_NAME (username $PGUSER)"
fi

step "2. IAM role (lets the proxy read that secret)"
cat >"$TMP_DIR/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"%s"}]}' "$SECRET_ARN" > "$TMP_DIR/policy.json"
if aws iam get-role --role-name "$PROXY_ROLE_NAME" >/dev/null 2>&1; then
  ok "Role $PROXY_ROLE_NAME exists"
else
  aws iam create-role --role-name "$PROXY_ROLE_NAME" --assume-role-policy-document "file://$TMP_DIR/trust.json" \
    --description 'MyBank workshop RDS Proxy role' --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
  ok "Created role $PROXY_ROLE_NAME; waiting 10s for IAM to propagate"; sleep 10
fi
aws iam put-role-policy --role-name "$PROXY_ROLE_NAME" --policy-name "$PROXY_ROLE_POLICY_NAME" --policy-document "file://$TMP_DIR/policy.json"
ROLE_ARN=$(aws iam get-role --role-name "$PROXY_ROLE_NAME" --query Role.Arn --output text)
ok "Inline policy $PROXY_ROLE_POLICY_NAME: secretsmanager:GetSecretValue on the secret"

step "3. Security groups:  client --5432--> proxy SG --5432--> Aurora SG"
PROXY_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$PROXY_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -z "$PROXY_SG_ID" || "$PROXY_SG_ID" == None ]]; then
  PROXY_SG_ID=$(aws ec2 create-security-group --group-name "$PROXY_SG_NAME" --description 'MyBank workshop RDS Proxy SG' --vpc-id "$VPC_ID" --region "$AWS_REGION" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PROXY_SG_NAME},{Key=Project,Value=MyBankAuroraWorkshop}]" --query GroupId --output text)
  ok "Created proxy SG $PROXY_SG_ID"
else
  ok "Proxy SG $PROXY_SG_ID exists"
fi
sg_allow "$AURORA_SG_ID" 5432 --source-group "$PROXY_SG_ID"
[[ -n "${LAB_CIDR:-}" ]] && sg_allow "$PROXY_SG_ID" 5432 --cidr "$LAB_CIDR"
[[ -n "${CLIENT_SG_ID:-}" ]] && sg_allow "$PROXY_SG_ID" 5432 --source-group "$CLIENT_SG_ID"

step "4. Proxy $PROXY_NAME"
PSTATUS=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" --query 'DBProxies[0].Status' --output text 2>/dev/null || true)
if [[ -z "$PSTATUS" || "$PSTATUS" == None ]]; then
  aws rds create-db-proxy --db-proxy-name "$PROXY_NAME" --engine-family POSTGRESQL \
    --auth "[{\"AuthScheme\":\"SECRETS\",\"SecretArn\":\"$SECRET_ARN\",\"IAMAuth\":\"DISABLED\"}]" \
    --role-arn "$ROLE_ARN" --vpc-subnet-ids "${SUBNETS[@]}" --vpc-security-group-ids "$PROXY_SG_ID" --require-tls \
    --region "$AWS_REGION" --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
  ok "Create requested"
else
  ok "Proxy exists (status $PSTATUS)"
fi
proxy_status() { aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" --query 'DBProxies[0].Status' --output text; }
poll "proxy $PROXY_NAME" "available" 1200 proxy_status || die "Proxy did not become available"

step "5. Register the cluster as the proxy's target"
REG=$(aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" --target-group-name default --region "$AWS_REGION" \
  --query "length(Targets[?Type=='TRACKED_CLUSTER' && RdsResourceId=='$CLUSTER_ID'])" --output text 2>/dev/null || echo 0)
if [[ "$REG" == 0 ]]; then
  aws rds register-db-proxy-targets --db-proxy-name "$PROXY_NAME" --db-cluster-identifiers "$CLUSTER_ID" --region "$AWS_REGION" >/dev/null
  ok "Registered $CLUSTER_ID"
else
  ok "$CLUSTER_ID already registered"
fi

step "6. Wait for the writer target to be healthy (2-5 min; 'UNAVAILABLE / PENDING_PROXY_CAPACITY' at first is normal)"
LAST_REASON="x"; HEALTHY=0; T0=$(date +%s)
for ((n = 1; n <= 90; n++)); do
  read -r ST RS < <(writer_target_health)
  printf '          [%s] writer target: %-12s reason: %s (t+%ss)\n' "$(date +%H:%M:%S)" "$ST" "$RS" "$(( $(date +%s) - T0 ))"
  [[ "$ST" == AVAILABLE ]] && { HEALTHY=1; break; }
  [[ "$RS" != "$LAST_REASON" ]] && { hint_for_reason "$RS"; LAST_REASON="$RS"; }
  sleep 10
done
(( HEALTHY )) || { show_status; die "Writer target not AVAILABLE after 15 min (last: $ST $RS)"; }
ok "Writer target AVAILABLE — the proxy can log in to the database"

PROXY_ENDPOINT=$(aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" --query 'DBProxies[0].Endpoint' --output text)
PROXY_SECRET_ARN="$SECRET_ARN"
save_env proxy.env PROXY_ENDPOINT PROXY_SG_ID PROXY_SECRET_ARN
ok "Saved proxy.env"
show_status

step "Connect (from the client EC2 only — the endpoint resolves to private IPs)"
show_endpoint "RDS Proxy:" "$PROXY_ENDPOINT"; password_hint
if [[ -n "${CLIENT_IP:-}" ]]; then
  NEXT=("bash 10a-client-ec2.sh sync     # push proxy.env to the client" "bash 10a-client-ec2.sh ssh" "cd lab && bash 10b-proxy-demo.sh check   # on the EC2")
else
  NEXT=("bash 10a-client-ec2.sh create   # client EC2 inside the VPC" "bash 10a-client-ec2.sh sync" "bash 10a-client-ec2.sh ssh" "cd lab && bash 10b-proxy-demo.sh check   # on the EC2")
fi
lab_next "${NEXT[@]}"
lab_success "RDS Proxy is set up and its target is healthy"
