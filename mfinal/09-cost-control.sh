#!/usr/bin/env bash
# Read-only: what is billing right now, and the cost levers an Aurora DBA should know.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Cost control (read-only)"

step "What is running"
bash ./00-inventory.sh 2>/dev/null | sed -n '/==> /,/RESULT/p' | grep -v RESULT || true

step "Cost levers"
info "Instances bill per second while running; a STOPPED cluster bills only storage + backups."
info "Stop overnight between Day 1 and Day 2:  bash 09b-stop-start.sh stop   (auto-starts after 7 days)"
info "Storage: Aurora Standard (pay per I/O) vs I/O-Optimized (no I/O charge, higher instance/storage price)."
info "  current storage type: $(cq 'DBClusters[0].StorageType' 2>/dev/null || echo '?')  (aurora = Standard, aurora-iopt1 = I/O-Optimized)"
info "Readers: each is a full instance bill. Serverless v2 readers (11c) can scale down to ${SV2_MIN_ACU} ACU."
info "RDS Proxy bills per vCPU of the instances behind it. Client EC2 is t3.micro."
info "Blue/Green doubles the cluster while it exists. Clones bill only for changed pages + their instance."

lab_next "bash 09b-stop-start.sh stop     # end of day" "bash 90-teardown.sh            # end of course"
lab_success "cost overview shown"
