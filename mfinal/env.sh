#!/usr/bin/env bash
# MyBank Aurora lab configuration. Copy to env.sh and edit:  cp env.sh.example env.sh
# LAB ONLY: public DB + 0.0.0.0/0 + password in this file are deliberate for a classroom.
export AWS_REGION="us-east-1"

# ---- Aurora cluster
export CLUSTER_ID="mybank-cluster"
export WRITER_INSTANCE="mybank-writer"
export READER_INSTANCE="mybank-reader"
export CLUSTER_PG="mybank-cluster-pg18"          # cluster parameter group (created by 02, rds.logical_replication=1)
export INSTANCE_PG="mybank-instance-pg18"        # instance parameter group (created by 05b)
export ENGINE_VERSION="18.4"
export ENGINE_FAMILY="aurora-postgresql18"
export DB_INSTANCE_CLASS="db.t3.medium"
export BACKUP_RETENTION_DAYS="7"
export PUBLICLY_ACCESSIBLE="true"                 # lab: connect from laptops directly
export LAB_CIDR="0.0.0.0/0"                       # lab: who may reach tcp/5432 (and ssh to the client EC2)

# ---- Database login (used by psql commands the scripts print and by the live checks)
export PGUSER="mybank_admin"
export PGDATABASE="mybank"
export PGPORT="5432"
export PGPASSWORD=""                              # LAB: set the master password here to skip all prompts & enable live checks

# ---- Network (01-create-network.sh)
export VPC_CIDR="10.10.0.0/16"
export SUBNET1_CIDR="10.10.1.0/24"
export SUBNET2_CIDR="10.10.2.0/24"
export SUBNET3_CIDR="10.10.3.0/24"
export NAME_PREFIX="B02"
export DB_SUBNET_GROUP="b02-aurora-subnet-group"
export SG_NAME="B02-Aurora-Lab-SG"

# ---- Day 1 extras
export CUSTOM_ENDPOINT_ID="mybank-reporting"      # 03b custom endpoint
export SCALE_TO_CLASS="db.t3.large"               # 04b vertical scaling target
export CLONE_ID="mybank-clone"                    # 06b clone
export PITR_ID="mybank-pitr"                      # 06b point-in-time restore

# ---- RDS Proxy (10, 10a, 10b)
export PROXY_NAME="mybank-proxy"
export PROXY_ROLE_NAME="MyBankRDSProxyRole"
export PROXY_ROLE_POLICY_NAME="RDSProxySecretAccess"
export PROXY_SECRET_NAME="mybank-aurora-proxy-secret"
export PROXY_SG_NAME="mybank-rds-proxy-sg"
export CLIENT_NAME="mybank-client"
export CLIENT_SG_NAME="mybank-client-sg"
export CLIENT_KEY_NAME="mybank-lab-key"
export CLIENT_INSTANCE_TYPE="t3.micro"

# ---- Reader auto scaling (11, 11b) and Serverless v2 reader (11c)
export ASG_MIN_READERS="1"
export ASG_MAX_READERS="3"
export ASG_TARGET_CPU="30"                        # low on purpose so pgbench load triggers scale-out in class
export SERVERLESS_READER="mybank-serverless-reader"
export SV2_MIN_ACU="0.5"
export SV2_MAX_ACU="4"

# ---- S3 import/export (12, 13)
export S3_DATA_PREFIX="aurora-lab"
export S3_DATA_BUCKET=""                          # blank = mybank-aurora-lab-<account>-<region>
export S3_IMPORT_ROLE_NAME="MyBankAuroraS3ImportRole"
export S3_EXPORT_ROLE_NAME="MyBankAuroraS3ExportRole"

# ---- Blue/Green (14, 15)
export BG_NAME="mybank-blue-green"
export BG_TARGET_ENGINE_VERSION="18.6"            # blank = identical copy; 00-preflight lists valid targets

export LOG_GROUP="/aws/rds/cluster/${CLUSTER_ID}/postgresql"

# ---- Load helpers and the state files written by the scripts (do not edit those by hand)
_LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$_LAB_DIR/lib.sh"
for _f in B02-network.env endpoints.env proxy.env client.env s3-resources.env; do
  [[ -f "$_LAB_DIR/$_f" ]] && source "$_LAB_DIR/$_f"
done
unset _f
if [[ -z "${AWS_ACCOUNT_ID:-}" ]] && command -v aws >/dev/null 2>&1; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"; export AWS_ACCOUNT_ID
fi
if [[ -z "${S3_DATA_BUCKET:-}" && -n "${AWS_ACCOUNT_ID:-}" ]]; then export S3_DATA_BUCKET="mybank-aurora-lab-${AWS_ACCOUNT_ID}-${AWS_REGION}"; fi
return 0 2>/dev/null || true
