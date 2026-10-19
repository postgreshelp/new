#!/usr/bin/env bash
# Day-to-day troubleshooting kit, each step verified:
#   1. Performance Insights on every instance
#   2. Slow query log (log_min_duration_statement) -> CloudWatch Logs, read with `aws logs tail`
#   3. pg_stat_statements top queries
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Performance Insights, logs, pg_stat_statements"
need_endpoints
[[ "$(cluster_status)" == available ]] || die "Cluster must be available"
CHECKS_OK=0; CHECKS_WARN=0
pass() { ok "$*"; CHECKS_OK=$((CHECKS_OK+1)); }
soft() { warn "$*"; CHECKS_WARN=$((CHECKS_WARN+1)); }
confirm "Enable Performance Insights (free 7-day tier), set log_min_duration_statement=500ms, run a few slow queries"

step "1. Performance Insights"
while IFS= read -r i; do
  [[ -n "$i" ]] || continue
  if [[ "$(iq 'DBInstances[0].PerformanceInsightsEnabled' "$i")" == True ]]; then pass "$i: already enabled"; continue; fi
  if out=$(aws rds modify-db-instance --db-instance-identifier "$i" --enable-performance-insights --performance-insights-retention-period 7 \
            --apply-immediately --region "$AWS_REGION" 2>&1); then
    pass "$i: enable requested (no reboot needed)"
  else
    soft "$i: could not enable — ${out:0:160}"
  fi
done < <(cluster_instances)
info "View it: RDS console -> Databases -> $(current_writer) -> Monitoring (Database Insights / Performance Insights)."
info "Read it as: DB load (average active sessions) split by wait event, SQL, user."

step "2. Slow query log"
CUR=$(aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" \
  --query "Parameters[?ParameterName=='log_min_duration_statement'].ParameterValue | [0]" --output text)
if [[ "$CUR" == None || -z "$CUR" || "$CUR" == -1 ]]; then
  aws rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG" --region "$AWS_REGION" \
    --parameters "ParameterName=log_min_duration_statement,ParameterValue=500,ApplyMethod=immediate" >/dev/null
  pass "log_min_duration_statement set to 500 ms (dynamic, no reboot)"
else
  pass "log_min_duration_statement already $CUR ms in $CLUSTER_PG"
fi
EXPORTS=$(cq 'DBClusters[0].EnabledCloudwatchLogsExports')
[[ "$EXPORTS" == *postgresql* ]] && pass "postgresql log export to CloudWatch is on ($LOG_GROUP)" || soft "Log export is off; enable: aws rds modify-db-cluster --db-cluster-identifier $CLUSTER_ID --cloudwatch-logs-export-configuration EnableLogTypes=postgresql"

if can_sql; then
  poll "live log_min_duration_statement" "500ms 1s ${CUR}ms" 300 sql "$CLUSTER_WRITER" "show log_min_duration_statement" || true
  step "   Generating slow statements"
  MARK="mybank_slow_$(date +%s)"
  for n in 1 2 3; do sql "$CLUSTER_WRITER" "select '$MARK', pg_sleep(1.$n)" >/dev/null; done
  sql "$CLUSTER_WRITER" "select '$MARK', count(*) from generate_series(1,3000000) a" >/dev/null
  ok "Ran 4 statements > 500 ms tagged '$MARK'"
  info "Waiting for them to reach CloudWatch Logs (usually < 2 min)..."
  FOUND=0
  for ((t = 0; t < 18; t++)); do
    N=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --filter-pattern "\"$MARK\"" --start-time $(( ($(date +%s) - 900) * 1000 )) \
          --region "$AWS_REGION" --query 'length(events)' --output text 2>/dev/null || echo 0)
    [[ "$N" =~ ^[0-9]+$ ]] && (( N > 0 )) && { FOUND=$N; break; }
    sleep 10
  done
  if (( FOUND > 0 )); then
    pass "Slow statements found in CloudWatch Logs ($FOUND log lines)"
    aws logs filter-log-events --log-group-name "$LOG_GROUP" --filter-pattern "\"$MARK\"" --start-time $(( ($(date +%s) - 900) * 1000 )) \
      --region "$AWS_REGION" --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' | grep duration | head -4 | cut -c1-160 | sed 's/^/          /'
  else
    soft "Slow statements not in CloudWatch yet; try the tail command below in a minute"
  fi
else
  soft "PGPASSWORD not set: skipped generating/finding slow queries"
fi
info "Follow the log live (copy-paste):"
cmd "aws logs tail $LOG_GROUP --follow --since 10m --region $AWS_REGION"
cmd "aws logs tail $LOG_GROUP --since 1h --filter-pattern duration --region $AWS_REGION"

step "3. pg_stat_statements"
if can_sql; then
  sql "$CLUSTER_WRITER" "create extension if not exists pg_stat_statements" >/dev/null && pass "pg_stat_statements extension ready (preloaded by default on Aurora)"
  info "Top 5 by total time:"
  sql "$CLUSTER_WRITER" "select lpad(calls::text,6)||' calls '||lpad(round(total_exec_time)::text,8)||' ms  '||left(regexp_replace(query,'\s+',' ','g'),70) from pg_stat_statements order by total_exec_time desc limit 5" \
    | sed 's/^/          /' || soft "could not read pg_stat_statements"
else
  soft "Skipped (needs PGPASSWORD)"
fi
cmd "select calls, round(total_exec_time) total_ms, round(mean_exec_time,1) mean_ms, left(query,80) from pg_stat_statements order by total_exec_time desc limit 10;"

step "Summary"
info "$CHECKS_OK check(s) OK, $CHECKS_WARN warning(s)"
lab_next "bash 09-cost-control.sh"
if (( CHECKS_WARN == 0 )); then lab_success "PI enabled, slow log flowing to CloudWatch, pg_stat_statements ready"
else lab_success "done with $CHECKS_WARN warning(s) — see [WARN] lines above"; fi
