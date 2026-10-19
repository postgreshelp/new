#!/usr/bin/env bash
# RDS Proxy concept demos. Run ON THE CLIENT EC2 (inside the VPC), from ~/lab:
#   bash 10b-proxy-demo.sh check       # private DNS; direct vs proxy; backend PID reuse
#   bash 10b-proxy-demo.sh multiplex   # many short-lived clients: peak DB backends direct vs via proxy
#   bash 10b-proxy-demo.sh pinning     # idle sessions release DB connections; SET/temp table pins them
#   bash 10b-proxy-demo.sh failover    # 1-second probes via proxy and direct; run 04-failover-demo.sh on the laptop
# Tunables: CLIENTS=50 DURATION=60 (multiplex), SESSIONS=20 HOLD=30 (pinning)
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh 2>/dev/null
ACTION="${1:-check}"
lab_init "RDS Proxy demo: $ACTION"

: "${PROXY_ENDPOINT:?PROXY_ENDPOINT empty — on the laptop run 10-rds-proxy.sh, then: bash 10a-client-ec2.sh sync}"
: "${CLUSTER_WRITER:?CLUSTER_WRITER empty — on the laptop run: bash 10a-client-ec2.sh sync}"
command -v psql >/dev/null || die "psql not installed. Run this on the client EC2 (10a-client-ec2.sh)"
if [[ -z "${PGPASSWORD:-}" ]]; then read -r -s -p "  Password for $PGUSER: " PGPASSWORD; echo; fi
export PGPASSWORD
sql "$PROXY_ENDPOINT" "select 1" >/dev/null 2>&1 || die "Cannot connect through the proxy. Are you on the client EC2? Check: bash 10-rds-proxy.sh status (laptop)"

backends() {  # client backends on the WRITER for our user, excluding this counting session
  sql "$CLUSTER_WRITER" "select count(*) from pg_stat_activity where backend_type='client backend' and usename=current_user and pid<>pg_backend_pid()"
}

case "$ACTION" in
check)
  step "1. DNS: the proxy endpoint resolves to PRIVATE VPC addresses"
  getent hosts "$PROXY_ENDPOINT" | sed 's/^/          /' || true
  info "That is why a laptop outside the VPC can't connect, even with 0.0.0.0/0 in the SG."
  step "2. Same query, direct vs via proxy"
  Q="select 'server='||inet_server_addr()||' pid='||pg_backend_pid()||' role='||case when pg_is_in_recovery() then 'reader' else 'writer' end"
  info "direct: $(sql "$CLUSTER_WRITER" "$Q")"
  info "proxy : $(sql "$PROXY_ENDPOINT" "$Q")"
  step "3. Five NEW connections each: does the backend PID change?"
  declare -A DP=() PP=()
  for i in 1 2 3 4 5; do
    d=$(sql "$CLUSTER_WRITER" 'select pg_backend_pid()'); p=$(sql "$PROXY_ENDPOINT" 'select pg_backend_pid()')
    DP[$d]=1; PP[$p]=1
    printf '          connection %d   direct pid=%-7s  proxy pid=%s\n' "$i" "$d" "$p"
  done
  ok "Direct: ${#DP[@]} distinct backends for 5 connections (PostgreSQL forks a process per connection)"
  (( ${#PP[@]} < 5 )) && ok "Proxy: only ${#PP[@]} distinct backend(s) for 5 connections — pooled connections are reused" \
                      || warn "Proxy used 5 different backends this time (pool still warming up); run check again"
  step "Connect yourself (copy-paste)"
  show_endpoint "RDS Proxy:" "$PROXY_ENDPOINT"; show_endpoint "Writer direct:" "$CLUSTER_WRITER"
  lab_next "bash $0 multiplex" "bash $0 pinning" "bash $0 failover"
  lab_success "proxy reachable from inside the VPC; connection reuse shown" ;;
multiplex)
  command -v pgbench >/dev/null || die "pgbench missing: sudo dnf install -y postgresql17-contrib (or 16/15)"
  CLIENTS="${CLIENTS:-50}"; DURATION="${DURATION:-60}"
  if [[ "$(sql "$CLUSTER_WRITER" "select to_regclass('public.pgbench_accounts') is not null")" != t ]]; then
    info "Initialising pgbench tables on the writer (scale 5). DDL: don't do this while Blue/Green exists."
    pgbench "$(conninfo "$CLUSTER_WRITER")" -i -s 5 -q
  fi
  run_case() {  # run_case <label> <host>
    local label="$1" host="$2" log="/tmp/pgbench-$1.log" peak=0 n pid
    step "$label: $CLIENTS clients, NEW connection per transaction (-C), ${DURATION}s, read-only"
    info "DB backends before: $(backends)"
    pgbench "$(conninfo "$host")" -C -c "$CLIENTS" -j 4 -T "$DURATION" -S -n >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      n=$(backends 2>/dev/null || echo 0); (( n > peak )) && peak=$n
      printf '\r          DB backends now: %-4s  peak: %-4s' "$n" "$peak"; sleep 2
    done
    wait "$pid" || true; echo
    ok "$label: PEAK DB backends on the writer = $peak"
    grep -E '^(tps|latency average|number of failed)' "$log" | sed 's/^/          /' || tail -5 "$log"
    LAST_PEAK=$peak
  }
  run_case direct "$CLUSTER_WRITER"; PEAK_DIRECT=$LAST_PEAK
  run_case proxy  "$PROXY_ENDPOINT"; PEAK_PROXY=$LAST_PEAK
  step "Result"
  info "Peak DB backends: direct=$PEAK_DIRECT   via proxy=$PEAK_PROXY   (clients=$CLIENTS)"
  info "Laptop: CloudWatch ClientConnections vs DatabaseConnections (dimension ProxyName=$PROXY_NAME)."
  lab_next "bash $0 pinning"
  if (( PEAK_PROXY < PEAK_DIRECT )); then lab_success "proxy multiplexed $CLIENTS clients onto $PEAK_PROXY DB connections (direct needed $PEAK_DIRECT)"
  else warn "Proxy peak not lower this run (short run / small instance). Try CLIENTS=100 DURATION=120 bash $0 multiplex"; lab_success "multiplex run complete"; fi ;;
pinning)
  SESSIONS="${SESSIONS:-20}"; HOLD="${HOLD:-30}"
  open_sessions() {  # SESSIONS psql sessions via proxy run <sql>, then sit idle HOLD seconds; prints DB backends
    local i
    for ((i = 1; i <= SESSIONS; i++)); do
      ( printf '%s\n' "$1"; sleep "$HOLD" ) | psql "$(conninfo "$PROXY_ENDPOINT")" -X -q -o /dev/null >/dev/null 2>&1 &
    done
    sleep 10; LAST_BACKENDS=$(backends)
    info "client sessions open via proxy: $SESSIONS   DB backends on writer: $LAST_BACKENDS (baseline $BASE)"
    wait || true
  }
  BASE=$(backends)
  step "Phase 1: $SESSIONS idle sessions, plain queries (NOT pinned)"
  open_sessions "select 1;"; UNPINNED=$LAST_BACKENDS
  info "Idle between transactions, so the proxy hands the DB connection back to the pool."
  step "Phase 2: same, but each session runs SET + CREATE TEMP TABLE (PINNED)"
  open_sessions "set work_mem='8MB'; create temp table pin_demo(x int); select 1;"; PINNED=$LAST_BACKENDS
  info "Session state lives in that backend, so the proxy must keep one DB connection per client."
  info "Common pinning causes: SET, temp tables, PREPARE, advisory locks, LISTEN. Metric: DatabaseConnectionsCurrentlySessionPinned."
  lab_next "bash $0 failover"
  if (( PINNED > UNPINNED )); then lab_success "pinning shown: $UNPINNED DB backends unpinned vs $PINNED pinned for $SESSIONS clients"
  else warn "No clear difference this run; try SESSIONS=40"; lab_success "pinning run complete"; fi ;;
failover)
  step "Probing every second via PROXY and DIRECT (cluster endpoint). Ctrl-C to stop."
  info "Now, on the LAPTOP: bash 04-failover-demo.sh   — watch which probe recovers first."
  probe() {
    local label="$1" host="$2" out
    while true; do
      out=$(PGCONNECT_TIMEOUT=2 psql "$(conninfo "$host")" -X -A -t -q -F ' ' \
             -c "select inet_server_addr(), case when pg_is_in_recovery() then 'READER(!)' else 'writer' end" 2>&1 | head -1) || true
      [[ "$out" == *writer* || "$out" == *READER* ]] || out="FAIL  ${out:0:70}"
      printf '%s  %-6s %s\n' "$(date +%H:%M:%S)" "$label" "$out"; sleep 1
    done
  }
  trap 'LAB_DONE=1; kill 0 2>/dev/null; exit 0' INT TERM
  probe proxy "$PROXY_ENDPOINT" & probe direct "$CLUSTER_WRITER" & wait ;;
*) die "Usage: bash $0 {check|multiplex|pinning|failover}" ;;
esac
