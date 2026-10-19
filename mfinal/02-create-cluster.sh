#!/usr/bin/env bash
# Aurora PostgreSQL cluster + writer (AZ1, promotion tier 0) + reader (AZ2, promotion tier 1).
# The cluster parameter group is created with rds.logical_replication=1 up front, so Blue/Green
# needs no reboot later. Endpoints are saved to endpoints.env.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Create Aurora cluster"

step "Pre-checks"
: "${VPC_ID:?VPC_ID empty — run 01-create-network.sh first}" "${SG_ID:?SG_ID empty}" "${SUBNET1_ID:?}" "${SUBNET2_ID:?}"
cluster_exists && die "Cluster $CLUSTER_ID already exists ($(cluster_status)). Use: bash 03-status.sh"
SUBNET_VPC=$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" --query 'DBSubnetGroups[0].VpcId' --output text 2>/dev/null || true)
[[ "$SUBNET_VPC" == "$VPC_ID" ]] || die "DB subnet group $DB_SUBNET_GROUP is in '$SUBNET_VPC', expected $VPC_ID"
AZ1=$(aws ec2 describe-subnets --subnet-ids "$SUBNET1_ID" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
AZ2=$(aws ec2 describe-subnets --subnet-ids "$SUBNET2_ID" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
ok "Network OK: VPC $VPC_ID, SG $SG_ID, writer AZ $AZ1, reader AZ $AZ2"
info "Billable: cluster $CLUSTER_ID + 2 x $DB_INSTANCE_CLASS, aurora-postgresql $ENGINE_VERSION, public=$PUBLICLY_ACCESSIBLE"
info "Takes ~20-25 minutes (writer first, then reader, so the writer is deterministic)."
confirm "Create the cluster"

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -r -s -p "  Master password for $PGUSER (8+ chars; tip: put it in env.sh as PGPASSWORD): " PGPASSWORD; echo
  read -r -s -p "  Repeat password: " P2; echo
  [[ "$PGPASSWORD" == "$P2" ]] || die "Passwords do not match"
  export PGPASSWORD
fi
(( ${#PGPASSWORD} >= 8 )) || die "Password must be at least 8 characters"
[[ "$PGPASSWORD" != *[/\"@\ ]* ]] || die "Password cannot contain / \" @ or spaces (Aurora rule)"

step "Cluster parameter group $CLUSTER_PG"
if aws rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" >/dev/null 2>&1; then
  ok "Exists; reusing"
else
  aws rds create-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" --db-parameter-group-family "$ENGINE_FAMILY" \
    --description 'MyBank Aurora workshop cluster parameters' --region "$AWS_REGION" --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
  ok "Created ($ENGINE_FAMILY)"
fi
aws rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" \
  --parameters "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" >/dev/null
ok "rds.logical_replication=1 (static; takes effect at first boot, so Blue/Green is ready without a reboot)"

step "Cluster $CLUSTER_ID"
aws rds create-db-cluster --region "$AWS_REGION" --no-cli-pager \
  --db-cluster-identifier "$CLUSTER_ID" --engine aurora-postgresql --engine-version "$ENGINE_VERSION" \
  --master-username "$PGUSER" --master-user-password "$PGPASSWORD" --database-name "$PGDATABASE" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" --vpc-security-group-ids "$SG_ID" \
  --db-cluster-parameter-group-name "$CLUSTER_PG" --backup-retention-period "$BACKUP_RETENTION_DAYS" \
  --storage-encrypted --deletion-protection --enable-cloudwatch-logs-exports postgresql \
  --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
ok "Create requested"
poll "cluster $CLUSTER_ID" "available" 1200 cluster_status || die "Cluster did not become available"
ok "Cluster available (storage volume exists, no compute yet)"

step "Instances"
ACCESS=$(access_flag)
aws rds create-db-instance --region "$AWS_REGION" --no-cli-pager --db-instance-identifier "$WRITER_INSTANCE" --db-cluster-identifier "$CLUSTER_ID" \
  --engine aurora-postgresql --db-instance-class "$DB_INSTANCE_CLASS" --availability-zone "$AZ1" --promotion-tier 0 "$ACCESS" \
  --tags Key=Project,Value=MyBankAuroraWorkshop Key=Role,Value=writer >/dev/null
ok "Writer $WRITER_INSTANCE requested (AZ $AZ1, tier 0 = first to be created becomes writer)"
poll "writer $WRITER_INSTANCE" "available" 1800 instance_status "$WRITER_INSTANCE" || die "Writer did not become available"
aws rds create-db-instance --region "$AWS_REGION" --no-cli-pager --db-instance-identifier "$READER_INSTANCE" --db-cluster-identifier "$CLUSTER_ID" \
  --engine aurora-postgresql --db-instance-class "$DB_INSTANCE_CLASS" --availability-zone "$AZ2" --promotion-tier 1 "$ACCESS" \
  --tags Key=Project,Value=MyBankAuroraWorkshop Key=Role,Value=reader >/dev/null
ok "Reader $READER_INSTANCE requested (AZ $AZ2, tier 1 = preferred failover target)"
poll "reader $READER_INSTANCE" "available" 1800 instance_status "$READER_INSTANCE" || die "Reader did not become available"

CLUSTER_WRITER=$(cq 'DBClusters[0].Endpoint'); CLUSTER_READER=$(cq 'DBClusters[0].ReaderEndpoint')
WRITER_INSTANCE_ENDPOINT=$(iq 'DBInstances[0].Endpoint.Address' "$WRITER_INSTANCE")
READER_INSTANCE_ENDPOINT=$(iq 'DBInstances[0].Endpoint.Address' "$READER_INSTANCE")
save_env endpoints.env CLUSTER_WRITER CLUSTER_READER WRITER_INSTANCE_ENDPOINT READER_INSTANCE_ENDPOINT
ok "Endpoints saved to endpoints.env"

step "Verify: connect through each endpoint"
db_check "Cluster (writer) endpoint" "$CLUSTER_WRITER" || warn "Check PUBLICLY_ACCESSIBLE / LAB_CIDR / your network, then: bash 03-status.sh"
db_check "Reader endpoint" "$CLUSTER_READER" || true
if can_sql; then
  LR=$(sql "$CLUSTER_WRITER" "show rds.logical_replication" 2>/dev/null || echo "?")
  [[ "$LR" == on ]] && ok "rds.logical_replication = on (Blue/Green prerequisite already met)" || warn "rds.logical_replication = $LR"
fi

step "Connect (copy-paste)"
show_endpoint "Writer (cluster endpoint):" "$CLUSTER_WRITER"
show_endpoint "Readers (reader endpoint):" "$CLUSTER_READER"
show_endpoint "Writer instance (direct):" "$WRITER_INSTANCE_ENDPOINT"
show_endpoint "Reader instance (direct):" "$READER_INSTANCE_ENDPOINT"
password_hint

lab_next "bash 03-status.sh" "psql \"$(conninfo "$CLUSTER_WRITER")\" -f 16-aurora-vs-onprem.sql"
lab_success "cluster $CLUSTER_ID is up with 1 writer + 1 reader"
