#!/usr/bin/env bash
# Read-only: CloudWatch basics per instance (CPU, connections, freeable memory, replica lag) + SQL views to know.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Monitoring basics (read-only)"
need_endpoints

read -r START END < <(python3 -c 'import datetime as d; n=d.datetime.now(d.timezone.utc); f="%Y-%m-%dT%H:%M:%SZ"; print((n-d.timedelta(minutes=30)).strftime(f), n.strftime(f))')
metric() {  # metric <instance> <name> -> latest 5-min average or '-'
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name "$2" --dimensions Name=DBInstanceIdentifier,Value="$1" \
    --start-time "$START" --end-time "$END" --period 300 --statistics Average --region "$AWS_REGION" \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Average' --output text 2>/dev/null | sed 's/None/-/' | awk '{ if ($1=="-") print "-"; else printf "%.1f\n", $1 }'
}

step "CloudWatch, last 5-minute average (last 30 min window)"
WRITER=$(current_writer)
printf '  %-28s %-7s %8s %8s %14s %14s\n' INSTANCE ROLE "CPU%" CONNS "FREE_MEM_MB" "REPL_LAG_ms"
while IFS= read -r i; do
  [[ -n "$i" ]] || continue
  role=reader; [[ "$i" == "$WRITER" ]] && role=WRITER
  mem=$(metric "$i" FreeableMemory); [[ "$mem" != - ]] && mem=$(awk -v m="$mem" 'BEGIN{printf "%.0f", m/1048576}')
  lag="-"; [[ $role == reader ]] && lag=$(metric "$i" AuroraReplicaLag)
  printf '  %-28s %-7s %8s %8s %14s %14s\n' "$i" "$role" "$(metric "$i" CPUUtilization)" "$(metric "$i" DatabaseConnections)" "$mem" "$lag"
done < <(cluster_instances)
info "'-' = no datapoint yet (new or idle instance). Replica lag on Aurora is usually ~10-30 ms:"
info "readers share the writer's storage, so there is no WAL replay of data files like streaming replication."

step "SQL you will use daily (copy-paste into psql)"
psql_cmd "$CLUSTER_WRITER"
cmd "select pid, usename, state, wait_event_type, wait_event, now()-query_start as runtime, left(query,60) from pg_stat_activity where state <> 'idle';"
cmd "select server_id, session_id, replica_lag_in_msec, cpu from aurora_replica_status();"
cmd "select datname, numbackends, xact_commit, blks_hit*100/nullif(blks_hit+blks_read,0) as hit_pct from pg_stat_database where datname=current_database();"
if can_sql; then
  step "Live: replica status"
  sql "$CLUSTER_WRITER" "select server_id||'  lag_ms='||coalesce(replica_lag_in_msec::text,'writer') from aurora_replica_status()" | sed 's/^/          /' || true
fi

lab_next "bash 08b-insights-logs.sh     # Performance Insights, slow query log, pg_stat_statements"
lab_success "metrics shown"
