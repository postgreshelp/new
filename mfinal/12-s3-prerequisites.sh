#!/usr/bin/env bash
# S3 import/export for Aurora PostgreSQL (aws_s3 extension):
#   bucket + sample CSV, two IAM roles (one per feature: s3Import / s3Export — AWS allows one role per feature),
#   associate them with the cluster, wait for ACTIVE, then RUN the import/export SQL and verify the result.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "S3 import/export"
need_endpoints
[[ "$(cluster_status)" == available ]] || die "Cluster must be available"
IMPORT_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/$S3_IMPORT_ROLE_NAME"; EXPORT_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:role/$S3_EXPORT_ROLE_NAME"
S3_KEY="$S3_DATA_PREFIX/organizations.csv"; S3_EXPORT_KEY="$S3_DATA_PREFIX/export/organizations-export.csv"

info "Bucket s3://$S3_DATA_BUCKET  prefix $S3_DATA_PREFIX/"
info "Roles: $S3_IMPORT_ROLE_NAME (read) -> s3Import, $S3_EXPORT_ROLE_NAME (write) -> s3Export"
confirm "Set up S3 import/export"
TMP_DIR=$(mktemp -d); on_cleanup "rm -rf '$TMP_DIR'"

step "1. Bucket and sample data"
if aws s3api head-bucket --bucket "$S3_DATA_BUCKET" >/dev/null 2>&1; then ok "Bucket exists"
else
  if [[ "$AWS_REGION" == us-east-1 ]]; then aws s3api create-bucket --bucket "$S3_DATA_BUCKET" --region "$AWS_REGION" >/dev/null
  else aws s3api create-bucket --bucket "$S3_DATA_BUCKET" --region "$AWS_REGION" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null; fi
  aws s3api put-bucket-tagging --bucket "$S3_DATA_BUCKET" --tagging 'TagSet=[{Key=Project,Value=MyBankAuroraWorkshop}]'
  ok "Created bucket (private + encrypted by default)"
fi
[[ -f organizations.csv ]] || printf 'organization_id,organization_name\n1,OpenAI\n2,Amazon\n3,Google\n4,Microsoft\n5,Oracle\n' > organizations.csv
EXPECTED_ROWS=$(( $(wc -l < organizations.csv) - 1 ))
aws s3 cp ./organizations.csv "s3://$S3_DATA_BUCKET/$S3_KEY" --region "$AWS_REGION" --only-show-errors
ok "Uploaded organizations.csv ($EXPECTED_ROWS data rows + header) to s3://$S3_DATA_BUCKET/$S3_KEY"

step "2. IAM roles (trusted by rds.amazonaws.com)"
cat > "$TMP_DIR/trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"]}]}' "$S3_DATA_BUCKET" "$S3_DATA_BUCKET" > "$TMP_DIR/import.json"
printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:PutObject","s3:AbortMultipartUpload","s3:ListBucket","s3:ListMultipartUploadParts","s3:ListBucketMultipartUploads"],"Resource":["arn:aws:s3:::%s","arn:aws:s3:::%s/*"]}]}' "$S3_DATA_BUCKET" "$S3_DATA_BUCKET" > "$TMP_DIR/export.json"
ensure_role() {  # ensure_role <role> <policy-file>
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$1" --policy-document "file://$TMP_DIR/trust.json"; ok "Role $1 exists (trust policy refreshed)"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "file://$TMP_DIR/trust.json" --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
    ok "Created role $1"; NEW_ROLE=1
  fi
  aws iam put-role-policy --role-name "$1" --policy-name "${1}-s3" --policy-document "file://$2"
  ok "Inline policy ${1}-s3 attached"
}
NEW_ROLE=0
ensure_role "$S3_IMPORT_ROLE_NAME" "$TMP_DIR/import.json"
ensure_role "$S3_EXPORT_ROLE_NAME" "$TMP_DIR/export.json"
(( NEW_ROLE )) && { info "Waiting 10s for IAM propagation"; sleep 10; }

step "3. Associate roles with the cluster"
role_state() { cq "DBClusters[0].AssociatedRoles[?FeatureName=='$1'].Status | [0]"; }
for pair in "s3Import:$IMPORT_ARN" "s3Export:$EXPORT_ARN"; do
  feature=${pair%%:*}; arn=${pair#*:}
  cur=$(role_state "$feature")
  if [[ -z "$cur" || "$cur" == None ]]; then
    aws rds add-role-to-db-cluster --db-cluster-identifier "$CLUSTER_ID" --feature-name "$feature" --role-arn "$arn" --region "$AWS_REGION"
    ok "$feature -> ${arn##*/} requested"
  else
    ok "$feature already associated ($cur)"
  fi
  poll "$feature association" "ACTIVE" 300 role_state "$feature" || die "$feature association not ACTIVE (status: $(role_state "$feature"))"
done
S3_IMPORT_ROLE_ARN="$IMPORT_ARN"; S3_EXPORT_ROLE_ARN="$EXPORT_ARN"
save_env s3-resources.env S3_DATA_BUCKET S3_IMPORT_ROLE_ARN S3_EXPORT_ROLE_ARN
ok "Saved s3-resources.env"

step "4. Run the SQL (13-s3-import-export.sql) — copy-paste"
PSQL_RUN="psql \"$(conninfo "$CLUSTER_WRITER")\" -v s3_bucket=$S3_DATA_BUCKET -v s3_key=$S3_KEY -v s3_export_key=$S3_EXPORT_KEY -v aws_region=$AWS_REGION -f 13-s3-import-export.sql"
cmd "$PSQL_RUN"
if can_sql; then
  info "Running it now..."
  OUT=$(eval "$PSQL_RUN" 2>&1) || { echo "$OUT" | tail -15 | sed 's/^/          /'; die "SQL failed (if it hangs/times out: the cluster has no route to S3 — 01 creates an S3 gateway endpoint)"; }
  echo "$OUT" | sed 's/^/          /'
  step "Verify"
  GOT=$(sql "$CLUSTER_WRITER" "select count(*) from staging.organizations")
  [[ "$GOT" == "$EXPECTED_ROWS" ]] && ok "Import: staging.organizations has $GOT rows (expected $EXPECTED_ROWS)" || die "Import: $GOT rows, expected $EXPECTED_ROWS"
  if aws s3 ls "s3://$S3_DATA_BUCKET/$S3_EXPORT_KEY" --region "$AWS_REGION" >/dev/null 2>&1; then
    ok "Export: object s3://$S3_DATA_BUCKET/$S3_EXPORT_KEY exists"
    cmd "aws s3 cp s3://$S3_DATA_BUCKET/$S3_EXPORT_KEY - --region $AWS_REGION    # view the exported CSV"
  else die "Export object not found in S3"; fi
  RESULT="import ($GOT rows) and export verified"
else
  warn "PGPASSWORD not set: run the command above yourself; expect imported_rows = $EXPECTED_ROWS"
  RESULT="S3 prerequisites ready (SQL not run)"
fi
lab_next "bash 14-bluegreen-ready.sh"
lab_success "$RESULT"
