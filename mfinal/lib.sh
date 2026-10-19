#!/usr/bin/env bash
# Shared helpers for the MyBank Aurora lab. Sourced by env.sh; defines functions only.
# A script opts in to the status banner with:  lab_init "What this script does"
# and ends with:                               lab_success "What was achieved"  +  lab_next "cmd" "cmd" ...

# ------------------------------------------------------------------ output
if [[ -t 1 ]]; then C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_G=""; C_R=""; C_Y=""; C_C=""; C_B=""; C_0=""; fi

step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s[OK]%s    %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s[WARN]%s  %s\n' "$C_Y" "$C_0" "$*"; }
info() { printf '          %s\n' "$*"; }
die()  { printf '  %s[ERROR]%s %s\n' "$C_R" "$C_0" "$*" >&2; LAB_FAIL_MSG="$*"; exit 1; }
cmd()  { printf '          %s%s%s\n' "$C_C" "$*" "$C_0"; }   # a copy-paste command

# ------------------------------------------------------------------ lifecycle + final RESULT banner
lab_init() {
  LAB_SCRIPT="$(basename -- "$0")"; LAB_TITLE="$1"; LAB_DONE=0; LAB_CANCELLED=0; LAB_FAIL_MSG=""; LAB_CLEANUPS=()
  LAB_START=$(date +%s)
  printf '%s#################### %s — %s%s\n' "$C_B" "$LAB_SCRIPT" "$LAB_TITLE" "$C_0"
  printf '          account/region: %s / %s   cluster: %s\n' "${AWS_ACCOUNT_ID:-?}" "$AWS_REGION" "$CLUSTER_ID"
  trap '_lab_err $LINENO "$BASH_COMMAND"' ERR
  trap '_lab_exit' EXIT
}
on_cleanup() { LAB_CLEANUPS+=("$1"); }
_lab_err() { LAB_ERR_LINE="$1"; LAB_ERR_CMD="$2"; }
_lab_exit() {
  local rc=$? c secs
  for c in "${LAB_CLEANUPS[@]:-}"; do [[ -n "$c" ]] && eval "$c" >/dev/null 2>&1 || true; done
  secs=$(( $(date +%s) - ${LAB_START:-$(date +%s)} ))
  echo
  if (( rc != 0 )); then
    printf '%s==================== RESULT: FAILED (%s, after %ss)%s\n' "$C_R" "$LAB_SCRIPT" "$secs" "$C_0"
    [[ -n "${LAB_FAIL_MSG:-}" ]] && printf '  Reason : %s\n' "$LAB_FAIL_MSG"
    [[ -z "${LAB_FAIL_MSG:-}" && -n "${LAB_ERR_LINE:-}" ]] && printf '  Failed at line %s: %s\n' "$LAB_ERR_LINE" "$LAB_ERR_CMD"
    printf '  Fix the error shown above and re-run: bash %s   (scripts are safe to re-run)\n' "$LAB_SCRIPT"
  elif [[ "${LAB_CANCELLED:-0}" == 1 ]]; then
    printf '%s==================== RESULT: CANCELLED — nothing was changed%s\n' "$C_Y" "$C_0"
  elif [[ "${LAB_DONE:-0}" != 1 ]]; then
    printf '%s==================== RESULT: INCOMPLETE (%s stopped early, after %ss)%s\n' "$C_Y" "$LAB_SCRIPT" "$secs" "$C_0"
  fi
  if [[ -n "${LAB_NEXT_TEXT:-}" ]]; then printf '%s' "$LAB_NEXT_TEXT"; fi
}
lab_success() {
  LAB_DONE=1
  local secs=$(( $(date +%s) - ${LAB_START:-$(date +%s)} ))
  printf '\n%s==================== RESULT: SUCCESS — %s (%ss)%s\n' "$C_G" "$*" "$secs" "$C_0"
}
lab_next() {   # printed after the RESULT line (also on failure, so keep it to useful commands)
  LAB_NEXT_TEXT=$(printf '%sNext:%s\n' "$C_B" "$C_0"; for l in "$@"; do printf '  %s%s%s\n' "$C_C" "$l" "$C_0"; done)$'\n'
}
lab_cancel() { LAB_CANCELLED=1; exit 0; }

# confirm "Create the lab network"  ->  y/N prompt. LAB_YES=1 answers yes automatically.
confirm() {
  [[ "${LAB_YES:-0}" == 1 ]] && { info "LAB_YES=1: auto-confirmed: $1"; return 0; }
  local a; read -r -p "  ${C_Y}?${C_0} $1 [y/N]: " a
  [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]] || lab_cancel
}

# ------------------------------------------------------------------ state files (*.env written by scripts, sourced by env.sh)
save_env() {  # save_env <file> VAR [VAR...]
  local f="$1" v; shift
  : > "$f"; for v in "$@"; do printf 'export %s=%q\n' "$v" "${!v-}" >> "$f"; done; chmod 600 "$f"
}

# ------------------------------------------------------------------ AWS shortcuts
cq() {  # cq '<jmespath>' [cluster-id]   -> describe-db-clusters as text
  aws rds describe-db-clusters --db-cluster-identifier "${2:-$CLUSTER_ID}" --region "$AWS_REGION" --query "$1" --output text 2>/dev/null
}
iq() {  # iq '<jmespath>' <instance-id>
  aws rds describe-db-instances --db-instance-identifier "$2" --region "$AWS_REGION" --query "$1" --output text 2>/dev/null
}
cluster_exists()   { [[ -n "$(cq 'DBClusters[0].Status' "${1:-$CLUSTER_ID}")" ]]; }
cluster_status()   { cq 'DBClusters[0].Status' "${1:-$CLUSTER_ID}" || echo "not-found"; }
instance_status()  { iq 'DBInstances[0].DBInstanceStatus' "$1" || echo "not-found"; }
current_writer()   { cq 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier | [0]' "${1:-$CLUSTER_ID}"; }
current_readers()  { cq 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`false`].DBInstanceIdentifier' "${1:-$CLUSTER_ID}" | tr '\t' '\n' | grep -v '^None$' || true; }
cluster_instances(){ aws rds describe-db-instances --filters "Name=db-cluster-id,Values=${1:-$CLUSTER_ID}" --region "$AWS_REGION" \
                       --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true; }
access_flag()      { if [[ "${PUBLICLY_ACCESSIBLE,,}" == true ]]; then echo --publicly-accessible; else echo --no-publicly-accessible; fi; }

# poll "<what>" "<wanted states, space separated>" <max_seconds> <command...>
# Prints a line whenever the state changes; returns 0 when the command prints a wanted state.
poll() {
  local what="$1" want="$2" max="$3"; shift 3
  local start now cur last="" interval=10
  start=$(date +%s)
  while :; do
    cur=$("$@" 2>/dev/null || true); cur="${cur:-none}"
    now=$(( $(date +%s) - start ))
    if [[ "$cur" != "$last" ]]; then printf '          [%s] %s: %s (t+%ss)\n' "$(date +%H:%M:%S)" "$what" "$cur" "$now"; last="$cur"; fi
    [[ " $want " == *" $cur "* ]] && return 0
    (( now >= max )) && { warn "$what still '$cur' after ${max}s"; return 1; }
    sleep "$interval"
  done
}

# try "<description>" <command...>  -> [OK] or [WARN] with the AWS error, never aborts (used by cleanup)
try() {
  local d="$1" out; shift
  if out=$("$@" 2>&1); then ok "$d"; else warn "$d — ${out:0:220}"; fi
  return 0
}

# Adds an SG ingress rule; "already exists" is fine. sg_allow <sg> <port> --cidr X | --source-group sg-Y
sg_allow() {
  local target="$1" port="$2" out; shift 2
  if out=$(aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$target" --protocol tcp --port "$port" "$@" 2>&1); then
    ok "SG $target: allow tcp/$port from ${*: -1}"
  elif [[ "$out" == *InvalidPermission.Duplicate* ]]; then
    ok "SG $target: tcp/$port from ${*: -1} already allowed"
  else
    die "Could not add SG rule on $target: $out"
  fi
}

# ------------------------------------------------------------------ PostgreSQL helpers
conninfo() { printf 'host=%s port=%s dbname=%s user=%s sslmode=require' "$1" "${PGPORT:-5432}" "${2:-$PGDATABASE}" "$PGUSER"; }
# psql_cmd <host> [db]  -> prints a copy-paste psql command
psql_cmd() { cmd "psql \"$(conninfo "$1" "${2:-}")\""; }
# show_endpoint "<label>" <host>  -> label, host, and the psql command
show_endpoint() {
  printf '  %-30s %s\n' "$1" "$2"
  psql_cmd "$2"
}
password_hint() {
  [[ -n "${PGPASSWORD:-}" ]] && info "(PGPASSWORD is set in env.sh, so psql will not prompt)" \
                             || info "(psql will prompt for the master password; set PGPASSWORD in env.sh to skip prompts)"
}
can_sql() { command -v psql >/dev/null 2>&1 && [[ -n "${PGPASSWORD:-}" ]]; }
# sql <host> "<sql>"  -> single value / rows, no headers (needs PGPASSWORD)
sql() { PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-8}" psql "$(conninfo "$1")" -X -A -t -q -v ON_ERROR_STOP=1 -c "$2"; }
# db_check "<label>" <host> : prints OK with server IP/role, or WARN. Returns 1 on failure.
db_check() {
  if ! command -v psql >/dev/null 2>&1; then warn "$1: psql not installed here; skipping live connection test"; return 0; fi
  if [[ -z "${PGPASSWORD:-}" ]]; then warn "$1: PGPASSWORD not set; skipping live connection test (set it in env.sh)"; return 0; fi
  local out
  if out=$(sql "$2" "select inet_server_addr()||' role='||case when pg_is_in_recovery() then 'reader' else 'writer' end||' version='||current_setting('server_version')" 2>&1); then
    ok "$1: connected (server $out)"
  else
    warn "$1: connection failed — ${out:0:200}"; return 1
  fi
}

# need_endpoints: fill CLUSTER_WRITER/CLUSTER_READER from AWS if endpoints.env is missing
need_endpoints() {
  cluster_exists || die "Cluster $CLUSTER_ID not found. Create it: bash 02-create-cluster.sh"
  [[ -n "${CLUSTER_WRITER:-}" ]] || CLUSTER_WRITER=$(cq 'DBClusters[0].Endpoint')
  [[ -n "${CLUSTER_READER:-}" ]] || CLUSTER_READER=$(cq 'DBClusters[0].ReaderEndpoint')
  export CLUSTER_WRITER CLUSTER_READER
}
