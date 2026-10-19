#!/usr/bin/env bash
# Hands-on parameter changes:
#   1. DYNAMIC, cluster level : log_min_duration_statement=500 in the cluster PG  -> live at once, no reboot
#   2. STATIC, instance level : max_connections=250 in a new instance PG on the writer -> pending-reboot, then reboot
#   bash 05b-param-change.sh          # do both
#   bash 05b-param-change.sh reset    # undo: reset both parameters (reboot asked for the static one)
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-run}"
lab_init "Parameter change: dynamic vs static"
need_endpoints
[[ "$(cluster_status)" == available ]] || die "Cluster must be available (now: $(cluster_status))"
WRITER=$(current_writer)
DYN_PARAM=log_min_duration_statement; DYN_VALUE=500
STATIC_PARAM=max_connections;          STATIC_VALUE=250

show_live() { can_sql && printf '          live SHOW %s = %s\n' "$1" "$(sql "$CLUSTER_WRITER" "show $1" 2>/dev/null || echo '?')" || true; }
instance_pg_status() { iq 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' "$WRITER"; }
reboot_writer() {
  confirm "Reboot writer $WRITER now (~1 min of downtime) so the static change applies"
  aws rds reboot-db-instance --db-instance-identifier "$WRITER" --region "$AWS_REGION" >/dev/null
  ok "Reboot requested"
  sleep 15
  poll "writer $WRITER" "available" 900 instance_status "$WRITER" || die "Writer did not come back"
  poll "instance PG apply status" "in-sync" 300 instance_pg_status || warn "Still not in-sync"
}

if [[ "$ACTION" == reset ]]; then
  step "Reset $DYN_PARAM in $CLUSTER_PG"
  aws rds reset-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" \
    --parameters "ParameterName=$DYN_PARAM,ApplyMethod=immediate" >/dev/null && ok "Reset requested"
  if aws rds describe-db-parameter-groups --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION" >/dev/null 2>&1; then
    step "Reset $STATIC_PARAM in $INSTANCE_PG"
    aws rds reset-db-parameter-group --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION" \
      --parameters "ParameterName=$STATIC_PARAM,ApplyMethod=pending-reboot" >/dev/null && ok "Reset requested (pending-reboot)"
    sleep 10; [[ "$(instance_pg_status)" == pending-reboot ]] && reboot_writer
  fi
  show_live "$DYN_PARAM"; show_live "$STATIC_PARAM"
  lab_next "bash 05-parameter-groups.sh"
  lab_success "parameters reset to defaults"; exit 0
fi

info "Will set $DYN_PARAM=$DYN_VALUE (cluster PG $CLUSTER_PG) and $STATIC_PARAM=$STATIC_VALUE (instance PG $INSTANCE_PG on $WRITER)."
can_sql || warn "PGPASSWORD not set: AWS-side steps run, but live SHOW checks are skipped"
confirm "Make the parameter changes"

# ------------------------------------------------------------------ 1. dynamic
step "1. DYNAMIC change at cluster level: $DYN_PARAM = $DYN_VALUE ms"
show_live "$DYN_PARAM"
aws rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" \
  --parameters "ParameterName=$DYN_PARAM,ParameterValue=$DYN_VALUE,ApplyMethod=immediate" >/dev/null
ok "Modified with ApplyMethod=immediate"
if can_sql; then
  poll "live $DYN_PARAM" "${DYN_VALUE}ms" 300 sql "$CLUSTER_WRITER" "show $DYN_PARAM" \
    && ok "Applied WITHOUT reboot — this is a dynamic parameter" || warn "Not visible yet; parameter propagation can take a few minutes"
fi
info "Effect: statements slower than ${DYN_VALUE}ms are logged (see 08b-insights-logs.sh)."

# ------------------------------------------------------------------ 2. static
step "2. STATIC change at instance level: $STATIC_PARAM = $STATIC_VALUE"
if aws rds describe-db-parameter-groups --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION" >/dev/null 2>&1; then
  ok "Instance PG $INSTANCE_PG exists"
else
  aws rds create-db-parameter-group --db-parameter-group-name "$INSTANCE_PG" --db-parameter-group-family "$ENGINE_FAMILY" \
    --description 'MyBank workshop instance parameters' --region "$AWS_REGION" --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
  ok "Created instance PG $INSTANCE_PG (until now instances used default.$ENGINE_FAMILY)"
fi
show_live "$STATIC_PARAM"
aws rds modify-db-parameter-group --db-parameter-group-name "$INSTANCE_PG" --region "$AWS_REGION" \
  --parameters "ParameterName=$STATIC_PARAM,ParameterValue=$STATIC_VALUE,ApplyMethod=pending-reboot" >/dev/null
ok "Set $STATIC_PARAM=$STATIC_VALUE (ApplyMethod=pending-reboot: static params can't apply immediately)"
CUR_PG=$(iq 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' "$WRITER")
if [[ "$CUR_PG" != "$INSTANCE_PG" ]]; then
  aws rds modify-db-instance --db-instance-identifier "$WRITER" --db-parameter-group-name "$INSTANCE_PG" --apply-immediately --region "$AWS_REGION" >/dev/null
  ok "Attached $INSTANCE_PG to writer $WRITER (reader keeps the default — compare them in 05-parameter-groups.sh)"
  sleep 15
  poll "writer status" "available" 600 instance_status "$WRITER" || true
fi
poll "instance PG apply status" "pending-reboot in-sync" 300 instance_pg_status || true
ST=$(instance_pg_status)
ok "Writer parameter status: $ST"
show_live "$STATIC_PARAM"
[[ "$ST" == pending-reboot ]] && { info "The new value is stored but NOT active yet. That is what 'pending-reboot' means."; reboot_writer; }

step "Verify"
RESULT="parameter changes applied"
if can_sql; then
  D=$(sql "$CLUSTER_WRITER" "show $DYN_PARAM" 2>/dev/null || true); S=$(sql "$CLUSTER_WRITER" "show $STATIC_PARAM" 2>/dev/null || true)
  [[ "$D" == "${DYN_VALUE}ms" ]] && ok "$DYN_PARAM = $D (dynamic, no reboot)" || warn "$DYN_PARAM = $D (expected ${DYN_VALUE}ms)"
  [[ "$S" == "$STATIC_VALUE" ]] && ok "$STATIC_PARAM = $S (static, after reboot)" || warn "$STATIC_PARAM = $S (expected $STATIC_VALUE)"
  [[ "$D" == "${DYN_VALUE}ms" && "$S" == "$STATIC_VALUE" ]] || RESULT="AWS changes done; live values not all confirmed yet"
else
  info "Check in psql:  SHOW $DYN_PARAM;  SHOW $STATIC_PARAM;"; psql_cmd "$CLUSTER_WRITER"
fi
lab_next "bash 05-parameter-groups.sh     # see Source=user params and per-instance groups" "bash 05b-param-change.sh reset   # undo"
lab_success "$RESULT"
