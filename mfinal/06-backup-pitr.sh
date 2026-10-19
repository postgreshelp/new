#!/usr/bin/env bash
# Backups: show the automated backup window (PITR range) and take a manual cluster snapshot.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Backups and manual snapshot"
cluster_exists || die "Cluster $CLUSTER_ID not found"

step "Automated backups = continuous, enable point-in-time restore"
read -r DAYS EARLIEST LATEST < <(cq 'DBClusters[0].[BackupRetentionPeriod,EarliestRestorableTime,LatestRestorableTime]')
ok "Retention: $DAYS day(s)"
ok "You can restore to any second between: $EARLIEST  and  $LATEST"
info "No backup window, no I/O freeze: Aurora backs up its storage volume continuously."

step "Existing manual snapshots"
aws rds describe-db-cluster-snapshots --db-cluster-identifier "$CLUSTER_ID" --snapshot-type manual --region "$AWS_REGION" \
  --query 'DBClusterSnapshots[].{Snapshot:DBClusterSnapshotIdentifier,Status:Status,Created:SnapshotCreateTime}' --output table

SNAP_ID="mybank-manual-$(date +%Y%m%d-%H%M%S)"
info "Manual snapshots are kept until you delete them (automated ones expire after $DAYS day(s))."
confirm "Create manual snapshot $SNAP_ID"

step "Snapshot $SNAP_ID"
aws rds create-db-cluster-snapshot --db-cluster-identifier "$CLUSTER_ID" --db-cluster-snapshot-identifier "$SNAP_ID" \
  --region "$AWS_REGION" --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
ok "Requested (the database stays fully online)"
snap_status() { aws rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "$SNAP_ID" --region "$AWS_REGION" --query 'DBClusterSnapshots[0].Status' --output text; }
poll "snapshot" "available" 1800 snap_status || die "Snapshot did not become available"
aws rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "$SNAP_ID" --region "$AWS_REGION" \
  --query 'DBClusterSnapshots[0].{Snapshot:DBClusterSnapshotIdentifier,Status:Status,Encrypted:StorageEncrypted,Engine:EngineVersion,Created:SnapshotCreateTime}' --output table

step "How you would restore it (not run here; 06b does a real PITR)"
cmd "aws rds restore-db-cluster-from-snapshot --db-cluster-identifier mybank-from-snap --snapshot-identifier $SNAP_ID --engine aurora-postgresql --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids ${SG_ID:-<sg>} --region $AWS_REGION"
info "...then add an instance: a restored cluster has NO instances until you create one."

lab_next "bash 06b-clone-pitr.sh clone   # fast copy-on-write clone" "bash 06b-clone-pitr.sh pitr    # recover a dropped table"
lab_success "snapshot $SNAP_ID is available"
