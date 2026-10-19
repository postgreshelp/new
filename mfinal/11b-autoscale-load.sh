#!/usr/bin/env bash
# Make auto scaling actually happen.
#   on the client EC2:  bash 11b-autoscale-load.sh load     # pgbench read-only load on the READER endpoint (default 20 min)
#   on the laptop:      bash 11b-autoscale-load.sh watch    # reader count + avg reader CPU every 30s; SUCCESS when a reader is added
# Tunables: CLIENTS=32 DURATION=1200 (load), WATCH_MINUTES=30 (watch)
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh 2>/dev/null
ACTION="${1:-}"
case "$ACTION" in load|watch) ;; *) echo "Usage: bash $0 {load|watch}"; exit 2;; esac
lab_init "Auto scaling: $ACTION"

if [[ "$ACTION" == load ]]; then
  : "${CLUSTER_READER:?CLUSTER_READER empty — endpoints.env missing (on the EC2 run: bash 10a-client-ec2.sh sync from the laptop)}"
  command -v pgbench >/dev/null || die "pgbench missing — run this on the client EC2 (10a-client-ec2.sh), or: sudo dnf install -y postgresql17-contrib"
  [[ -n "${PGPASSWORD:-}" ]] || { read -r -s -p "  Password for $PGUSER: " PGPASSWORD; echo; export PGPASSWORD; }
  CLIENTS="${CLIENTS:-32}"; DURATION="${DURATION:-1200}"
  step "pgbench tables"
  if [[ "$(sql "$CLUSTER_WRITER" "select to_regclass('public.pgbench_accounts') is not null")" == t ]]; then ok "pgbench tables exist"
  else
    info "Initialising on the WRITER (scale 10). DDL: don't do this while a Blue/Green deployment exists."
    pgbench "$(conninfo "$CLUSTER_WRITER")" -i -s 10 -q && ok "pgbench tables created"
  fi
  step "Load: $CLIENTS clients, select-only, ${DURATION}s, on the READER endpoint"
  info "Progress every 60s below. In parallel on the laptop: bash 11b-autoscale-load.sh watch"
  info "Expect: CPU above target ~3 min -> alarm -> new reader requested -> ~10 min to create it."
  pgbench "$(conninfo "$CLUSTER_READER")" -S -c "$CLIENTS" -j 4 -T "$DURATION" -n -P 60 \
    || die "pgbench failed (connection? password?)"
  lab_next "on laptop: bash 11b-autoscale-load.sh watch   # confirm the scale-out" "bash 11-reader-autoscaling.sh remove   # when done"
  lab_success "load run finished"
  exit 0
fi

# ------------------------------------------------------------------ watch (laptop, needs AWS credentials)
cluster_exists || die "Cluster $CLUSTER_ID not found"
POL=$(aws application-autoscaling describe-scaling-policies --service-namespace rds --resource-id "cluster:$CLUSTER_ID" --region "$AWS_REGION" \
  --query 'ScalingPolicies[0].TargetTrackingScalingPolicyConfiguration.TargetValue' --output text 2>/dev/null || true)
[[ -n "$POL" && "$POL" != None ]] || die "No auto scaling policy. Run first: bash 11-reader-autoscaling.sh"
reader_cpu() {
  local s e
  read -r s e < <(python3 -c 'import datetime as d; n=d.datetime.now(d.timezone.utc); f="%Y-%m-%dT%H:%M:%SZ"; print((n-d.timedelta(minutes=5)).strftime(f), n.strftime(f))')
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
    --dimensions Name=DBClusterIdentifier,Value="$CLUSTER_ID" Name=Role,Value=READER --start-time "$s" --end-time "$e" \
    --period 60 --statistics Average --region "$AWS_REGION" --query 'sort_by(Datapoints,&Timestamp)[-1].Average' --output text 2>/dev/null \
    | awk '{ if ($1=="None"||$1=="") print "-"; else printf "%.0f\n", $1 }'
}
START_READERS=$(current_readers | wc -l | tr -d ' ')
ok "Policy target ${POL%.*}% CPU; readers now: $START_READERS (max $ASG_MAX_READERS)"
WATCH_MINUTES="${WATCH_MINUTES:-30}"
step "Watching every 30s for up to $WATCH_MINUTES min (Ctrl-C to stop)"
printf '          %-8s %-9s %-8s %s\n' TIME READERS CPU% "READER INSTANCES (status)"
END=$(( $(date +%s) + WATCH_MINUTES * 60 ))
NEW=""
while (( $(date +%s) < END )); do
  LIST=""; N=0
  for i in $(current_readers); do LIST+="$i($(instance_status "$i")) "; N=$((N+1)); done
  for i in $(cluster_instances); do   # instances still 'creating' are not cluster members yet
    [[ " $LIST " == *" $i("* || "$i" == "$(current_writer)" ]] && continue
    LIST+="$i($(instance_status "$i")) "; N=$((N+1))
  done
  printf '          %-8s %-9s %-8s %s\n' "$(date +%H:%M:%S)" "$N" "$(reader_cpu)" "$LIST"
  NEW=$(cluster_instances | grep '^application-autoscaling-' | head -1 || true)
  if [[ -n "$NEW" && "$(instance_status "$NEW")" == available ]]; then break; fi
  sleep 30
done

if [[ -n "$NEW" && "$(instance_status "$NEW")" == available ]]; then
  ok "Auto scaling added reader $NEW"
  db_check "Reader endpoint" "$(cq 'DBClusters[0].ReaderEndpoint')" || true
  info "Stop the load and wait: after the scale-in cooldown AWS removes auto-added readers again (down to min $ASG_MIN_READERS)."
  lab_next "bash 03b-endpoints.sh demo    # reader endpoint now spreads over 2+ readers" "bash 11-reader-autoscaling.sh remove"
  lab_success "scale-out observed: $NEW joined the cluster"
elif [[ -n "$NEW" ]]; then
  warn "Scale-out in progress: $NEW is $(instance_status "$NEW"). Re-run watch to see it finish."
  lab_next "bash $0 watch"
  lab_success "scale-out triggered (reader still creating)"
else
  die "No scale-out within $WATCH_MINUTES min. Is the load running on the reader endpoint, and is CPU above ${POL%.*}%? Lower ASG_TARGET_CPU in env.sh and re-run 11-reader-autoscaling.sh"
fi
