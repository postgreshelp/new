#!/usr/bin/env bash
# Blue/Green readiness check. Ends with READY (SUCCESS) or NOT READY (FAILED + list of blockers).
# Fixes it can make (asks first): enable rds.logical_replication + reboot pending instances;
# create the bg_demo table used by 15-bluegreen.sh demo (DDL must happen BEFORE Blue/Green exists).
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Blue/Green readiness"
need_endpoints
BLOCKERS=(); WARNINGS=0
block() { warn "BLOCKER: $*"; BLOCKERS+=("$*"); }
note()  { warn "$*"; WARNINGS=$((WARNINGS+1)); }

step "1. Cluster"
read -r ENGINE VERSION STATUS PG < <(cq 'DBClusters[0].[Engine,EngineVersion,Status,DBClusterParameterGroup]')
[[ "$ENGINE" == aurora-postgresql && "$STATUS" == available ]] && ok "$CLUSTER_ID: $ENGINE $VERSION, $STATUS, cluster PG $PG" || block "cluster is $STATUS (must be available)"
[[ "$PG" == default.* ]] && block "cluster uses default parameter group $PG; Blue/Green needs a custom one with rds.logical_replication=1 (02 creates $CLUSTER_PG)"
EXISTING=$(aws rds describe-blue-green-deployments --region "$AWS_REGION" --query "BlueGreenDeployments[?BlueGreenDeploymentName=='$BG_NAME'].Status | [0]" --output text 2>/dev/null || true)
[[ -z "$EXISTING" || "$EXISTING" == None ]] && ok "No Blue/Green deployment named $BG_NAME yet" || note "Deployment $BG_NAME already exists ($EXISTING): use bash 15-bluegreen.sh status"

step "2. rds.logical_replication (Aurora PostgreSQL Blue/Green replicates with logical replication)"
VALUE=$(aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$PG" --region "$AWS_REGION" \
  --query "Parameters[?ParameterName=='rds.logical_replication'].ParameterValue | [0]" --output text)
PENDING=$(cq "DBClusters[0].DBClusterMembers[?DBClusterParameterGroupStatus!='in-sync'].DBInstanceIdentifier" | tr '\t' ' ' | sed 's/None//')
if [[ "$VALUE" != 1 || -n "${PENDING// /}" ]]; then
  warn "Configured value: $VALUE; instances not in-sync: ${PENDING:-none}"
  if [[ "$PG" != default.* ]]; then
    confirm "Fix it: set rds.logical_replication=1 and reboot the instances that need it (short outage each)"
    [[ "$VALUE" != 1 ]] && aws rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "$PG" --region "$AWS_REGION" \
      --parameters ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot >/dev/null && ok "Parameter set (pending-reboot)"
    sleep 10
    for i in $(cluster_instances); do
      st=$(cq "DBClusters[0].DBClusterMembers[?DBInstanceIdentifier=='$i'].DBClusterParameterGroupStatus | [0]")
      [[ "$st" == in-sync ]] && continue
      aws rds reboot-db-instance --db-instance-identifier "$i" --region "$AWS_REGION" >/dev/null; ok "Rebooting $i"
      sleep 15; poll "$i" "available" 900 instance_status "$i" || true
    done
    VALUE=$(aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$PG" --region "$AWS_REGION" \
      --query "Parameters[?ParameterName=='rds.logical_replication'].ParameterValue | [0]" --output text)
    PENDING=$(cq "DBClusters[0].DBClusterMembers[?DBClusterParameterGroupStatus!='in-sync'].DBInstanceIdentifier" | tr '\t' ' ' | sed 's/None//')
  fi
fi
[[ "$VALUE" == 1 && -z "${PENDING// /}" ]] && ok "Configured = 1 and all instances in-sync" || block "rds.logical_replication not applied on all instances (value=$VALUE, pending: $PENDING)"
if can_sql; then
  LIVE=$(sql "$CLUSTER_WRITER" "show rds.logical_replication" 2>/dev/null || echo '?')
  [[ "$LIVE" == on ]] && ok "Live: SHOW rds.logical_replication = on" || block "Live value is '$LIVE' (must be on)"
fi

step "3. Target version"
if [[ -n "${BG_TARGET_ENGINE_VERSION:-}" ]]; then
  TARGETS=$(aws rds describe-db-engine-versions --engine aurora-postgresql --engine-version "$VERSION" --region "$AWS_REGION" \
    --query 'DBEngineVersions[0].ValidUpgradeTarget[].EngineVersion' --output text | tr '\t' ' ')
  [[ " $TARGETS " == *" $BG_TARGET_ENGINE_VERSION "* ]] && ok "Green will run $BG_TARGET_ENGINE_VERSION (valid upgrade from $VERSION)" \
    || block "BG_TARGET_ENGINE_VERSION=$BG_TARGET_ENGINE_VERSION is not a valid upgrade from $VERSION (valid: ${TARGETS:-none})"
else
  note "BG_TARGET_ENGINE_VERSION is empty: green would be an identical copy (nothing to demonstrate). Set it in env.sh."
fi

step "4. Schema limitations (data that logical replication can't carry)"
if can_sql; then
  NOPK=$(sql "$CLUSTER_WRITER" "select string_agg(n.nspname||'.'||c.relname, ', ') from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema','aws_s3','aws_commons') and n.nspname not like 'pg_toast%'
         and not exists (select 1 from pg_index i where i.indrelid=c.oid and i.indisprimary) and c.relreplident <> 'f'")
  [[ -z "$NOPK" ]] && ok "Every table has a primary key" \
    || note "Tables without primary key: $NOPK — UPDATE/DELETE on them FAIL while Blue/Green exists (add a PK or REPLICA IDENTITY FULL)"
  LO=$(sql "$CLUSTER_WRITER" "select count(*) from pg_largeobject_metadata")
  [[ "$LO" == 0 ]] && ok "No large objects" || note "$LO large objects: not replicated, and creating new ones breaks replication"
  MV=$(sql "$CLUSTER_WRITER" "select count(*) from pg_matviews")
  [[ "$MV" == 0 ]] && ok "No materialized views" || note "$MV materialized views: REFRESH on blue breaks replication"
  UL=$(sql "$CLUSTER_WRITER" "select count(*) from pg_class where relpersistence='u' and relkind='r'")
  [[ "$UL" == 0 ]] && ok "No unlogged tables" || note "$UL unlogged tables: not replicated by default"
  if [[ "$(sql "$CLUSTER_WRITER" "select to_regclass('public.bg_demo') is not null")" != t ]]; then
    if [[ -z "$EXISTING" || "$EXISTING" == None ]]; then
      sql "$CLUSTER_WRITER" "create table bg_demo(id bigint generated always as identity primary key, note text, written_at timestamptz default now())" >/dev/null
      ok "Created table bg_demo (used by '15-bluegreen.sh demo'; must exist before the deployment)"
    else note "bg_demo missing and a deployment exists — creating it now would be DDL and break replication"; fi
  else ok "bg_demo table exists"; fi
else
  note "PGPASSWORD not set: schema checks skipped (primary keys, large objects, matviews)"
fi

step "5. Things that interact with Blue/Green"
if aws rds describe-db-proxies --db-proxy-name "$PROXY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  REG=$(aws rds describe-db-proxy-targets --db-proxy-name "$PROXY_NAME" --target-group-name default --region "$AWS_REGION" \
    --query "length(Targets[?Type=='TRACKED_CLUSTER' && RdsResourceId=='$CLUSTER_ID'])" --output text 2>/dev/null || echo 0)
  [[ "$REG" != 0 ]] && ok "RDS Proxy registered before Blue/Green (good: it follows the switchover)" || note "Proxy exists but cluster not registered; register NOW (blocked once Blue/Green exists): bash 10-rds-proxy.sh"
else ok "No RDS Proxy (fine)"; fi
POL=$(aws application-autoscaling describe-scaling-policies --service-namespace rds --resource-id "cluster:$CLUSTER_ID" --region "$AWS_REGION" --query 'ScalingPolicies[0].PolicyName' --output text 2>/dev/null || true)
[[ -n "$POL" && "$POL" != None ]] && note "Auto scaling policy $POL is NOT copied to green; re-run 11-reader-autoscaling.sh after switchover" || ok "No auto scaling policy"
info "While the deployment exists: no DDL on blue (CREATE/ALTER/DROP) — it puts green in 'Replication degraded';"
info "you can't stop the cluster; sequences are synced only at switchover."

step "Verdict"
info "$WARNINGS warning(s), ${#BLOCKERS[@]} blocker(s)"
if (( ${#BLOCKERS[@]} > 0 )); then
  for b in "${BLOCKERS[@]}"; do info "- $b"; done
  die "NOT READY for Blue/Green — fix the blockers above and re-run"
fi
lab_next "bash 15-bluegreen.sh create"
lab_success "READY for Blue/Green ($VERSION -> ${BG_TARGET_ENGINE_VERSION:-same version})"
