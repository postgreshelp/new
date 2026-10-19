#!/usr/bin/env bash
# Read-only checks before (and between) labs: tools, AWS identity, engine version, Blue/Green target, network state.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
[[ -f ./env.sh ]] || { echo "ERROR: run: cp env.sh.example env.sh  (then edit it)"; exit 2; }
source ./env.sh
lab_init "Preflight checks (read-only)"

step "Local tools"
command -v aws >/dev/null && ok "aws CLI: $(aws --version 2>&1 | cut -d' ' -f1)" || die "aws CLI not installed"
command -v python3 >/dev/null && ok "python3 present" || die "python3 not installed (used for date maths)"
if command -v psql >/dev/null; then ok "psql: $(psql --version)"; else warn "psql not installed on this machine — scripts still work, live SQL checks are skipped"; fi
[[ -n "${PGPASSWORD:-}" ]] && ok "PGPASSWORD set in env.sh (no prompts, live checks enabled)" \
                           || warn "PGPASSWORD empty in env.sh — psql will prompt and live SQL checks are skipped"

step "AWS identity"
ARN=$(aws sts get-caller-identity --query Arn --output text 2>&1) || die "AWS credentials not working: $ARN"
ok "Caller: $ARN"
ok "Account: $AWS_ACCOUNT_ID   Region: $AWS_REGION"

step "Engine version"
FOUND=$(aws rds describe-db-engine-versions --engine aurora-postgresql --engine-version "$ENGINE_VERSION" --region "$AWS_REGION" \
  --query 'DBEngineVersions[0].EngineVersion' --output text 2>/dev/null || true)
[[ "$FOUND" == "$ENGINE_VERSION" ]] || die "aurora-postgresql $ENGINE_VERSION is not offered in $AWS_REGION. List: aws rds describe-db-engine-versions --engine aurora-postgresql --query 'DBEngineVersions[].EngineVersion'"
ok "aurora-postgresql $ENGINE_VERSION available in $AWS_REGION (family $ENGINE_FAMILY)"
TARGETS=$(aws rds describe-db-engine-versions --engine aurora-postgresql --engine-version "$ENGINE_VERSION" --region "$AWS_REGION" \
  --query 'DBEngineVersions[0].ValidUpgradeTarget[].EngineVersion' --output text 2>/dev/null | tr '\t' ' ')
info "Valid upgrade targets (for Blue/Green): ${TARGETS:-none}"
if [[ -n "${BG_TARGET_ENGINE_VERSION:-}" ]]; then
  if [[ " $TARGETS " == *" $BG_TARGET_ENGINE_VERSION "* ]]; then ok "BG_TARGET_ENGINE_VERSION=$BG_TARGET_ENGINE_VERSION is a valid upgrade target"
  else warn "BG_TARGET_ENGINE_VERSION=$BG_TARGET_ENGINE_VERSION is NOT in the list above — fix env.sh before 15-bluegreen.sh"; fi
fi

step "Lab access mode"
info "PUBLICLY_ACCESSIBLE=$PUBLICLY_ACCESSIBLE  LAB_CIDR=${LAB_CIDR:-<none>}"
[[ "${PUBLICLY_ACCESSIBLE,,}" == true && -z "${LAB_CIDR:-}" ]] && die "PUBLICLY_ACCESSIBLE=true needs LAB_CIDR (lab default 0.0.0.0/0)"
ok "Lab mode: laptops connect directly to the cluster endpoints on 5432"

step "What already exists"
NEXT="bash 01-create-network.sh"
if [[ -n "${VPC_ID:-}" ]]; then
  if aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    ok "Network: VPC $VPC_ID (from B02-network.env)"
    NEXT="bash 02-create-cluster.sh"
  else
    die "B02-network.env points to VPC $VPC_ID which does not exist in this account/region. It is stale (copied from another account?). Delete B02-network.env and endpoints.env, then run 01-create-network.sh"
  fi
else
  info "Network: not created yet"
fi
if cluster_exists; then
  ok "Cluster $CLUSTER_ID: $(cluster_status)"
  NEXT="bash 03-status.sh"
else
  info "Cluster $CLUSTER_ID: not created yet"
fi

lab_next "$NEXT"
lab_success "preflight passed, no resources changed"
