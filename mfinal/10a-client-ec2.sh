#!/usr/bin/env bash
# Client EC2 INSIDE the Aurora VPC with psql + pgbench (Amazon Linux 2023, t3.micro).
# RDS Proxy endpoints are private, so proxy / load demos run from here.
#   bash 10a-client-ec2.sh create   # key pair + client SG + instance; verifies psql works on it
#   bash 10a-client-ec2.sh sync     # copy *.sh *.sql *.env *.csv to ~/lab on the EC2 (re-run after any script writes a .env)
#   bash 10a-client-ec2.sh ssh      # log in
#   bash 10a-client-ec2.sh test     # from the EC2: connect to writer endpoint (and proxy if it exists)
#   bash 10a-client-ec2.sh status | delete
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-create}"
lab_init "Client EC2: $ACTION"
CLIENT_KEY_FILE="./${CLIENT_KEY_NAME}.pem"
SSH_CIDR="${SSH_CIDR:-${LAB_CIDR:-0.0.0.0/0}}"
SSH_OPTS=(-i "$CLIENT_KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

persist() { save_env client.env CLIENT_INSTANCE_ID CLIENT_IP CLIENT_SG_ID CLIENT_KEY_NAME; }
find_instance() {
  aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=vpc-id,Values=${VPC_ID:-x}" "Name=tag:Name,Values=$CLIENT_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true
}
find_sg() { aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=vpc-id,Values=${VPC_ID:-x}" "Name=group-name,Values=$1" \
              --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true; }
public_ip() { aws ec2 describe-instances --instance-ids "$1" --region "$AWS_REGION" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }
remote() { ssh "${SSH_OPTS[@]}" "ec2-user@$CLIENT_IP" "$@"; }
require_ip() {
  [[ -n "${CLIENT_IP:-}" && "$CLIENT_IP" != None ]] || die "No client known. Run: bash $0 create"
  [[ -f "$CLIENT_KEY_FILE" ]] || die "Key file $CLIENT_KEY_FILE missing next to the scripts"
}
remote_test() {  # connect from the EC2 to writer (and proxy) using the synced env files
  local pw="${PGPASSWORD:-}"
  [[ -n "$pw" ]] || { warn "PGPASSWORD not set in env.sh: skipping connection test from the EC2"; return 0; }
  [[ -n "${CLUSTER_WRITER:-}" ]] || { warn "No cluster endpoints yet (endpoints.env): skipping connection test"; return 0; }
  local hosts=("$CLUSTER_WRITER"); [[ -n "${PROXY_ENDPOINT:-}" ]] && hosts+=("$PROXY_ENDPOINT")
  local h out
  for h in "${hosts[@]}"; do
    if out=$(remote "PGPASSWORD='$pw' PGCONNECT_TIMEOUT=5 psql \"$(conninfo "$h")\" -XAtc \"select inet_server_addr()\"" 2>&1); then
      ok "From the EC2 -> $h: connected (server $out)"
    else
      warn "From the EC2 -> $h: ${out:0:180}"; return 1
    fi
  done
}

case "$ACTION" in
create)
  : "${VPC_ID:?VPC_ID empty — run 01-create-network.sh}" "${SUBNET1_ID:?}" "${SG_ID:?}"
  EXISTING=$(find_instance)
  if [[ -n "$EXISTING" && "$EXISTING" != None ]]; then
    CLIENT_INSTANCE_ID="$EXISTING"; CLIENT_IP=$(public_ip "$EXISTING"); CLIENT_SG_ID=$(find_sg "$CLIENT_SG_NAME"); persist
    ok "Client already exists: $CLIENT_INSTANCE_ID ($CLIENT_IP)"
    lab_next "bash $0 sync" "bash $0 ssh"; lab_success "client already running"; exit 0
  fi
  info "Creates key pair $CLIENT_KEY_NAME (.pem saved here), SG $CLIENT_SG_NAME (ssh from $SSH_CIDR), $CLIENT_INSTANCE_TYPE in $SUBNET1_ID."
  confirm "Create the client EC2"

  step "Key pair"
  if aws ec2 describe-key-pairs --key-names "$CLIENT_KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    [[ -f "$CLIENT_KEY_FILE" ]] || die "Key pair exists in AWS but $CLIENT_KEY_FILE is missing. Delete it: aws ec2 delete-key-pair --key-name $CLIENT_KEY_NAME --region $AWS_REGION"
    ok "Reusing key pair $CLIENT_KEY_NAME"
  else
    rm -f "$CLIENT_KEY_FILE"
    aws ec2 create-key-pair --key-name "$CLIENT_KEY_NAME" --key-type rsa --region "$AWS_REGION" --query KeyMaterial --output text > "$CLIENT_KEY_FILE"
    chmod 400 "$CLIENT_KEY_FILE"; ok "Created key pair; private key in $CLIENT_KEY_FILE"
  fi

  step "Security groups"
  CLIENT_SG_ID=$(find_sg "$CLIENT_SG_NAME")
  if [[ -z "$CLIENT_SG_ID" || "$CLIENT_SG_ID" == None ]]; then
    CLIENT_SG_ID=$(aws ec2 create-security-group --group-name "$CLIENT_SG_NAME" --description 'MyBank workshop client EC2' --vpc-id "$VPC_ID" --region "$AWS_REGION" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=MyBankAuroraWorkshop}]" --query GroupId --output text)
    ok "Created SG $CLIENT_SG_ID"
  fi
  CLIENT_INSTANCE_ID=""; CLIENT_IP=""; persist
  sg_allow "$CLIENT_SG_ID" 22 --cidr "$SSH_CIDR"
  sg_allow "$SG_ID" 5432 --source-group "$CLIENT_SG_ID"
  P_SG="${PROXY_SG_ID:-$(find_sg "$PROXY_SG_NAME")}"
  [[ -n "$P_SG" && "$P_SG" != None ]] && sg_allow "$P_SG" 5432 --source-group "$CLIENT_SG_ID"

  step "Instance"
  AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --region "$AWS_REGION" --query 'Parameters[0].Value' --output text)
  USERDATA=$(mktemp); on_cleanup "rm -f '$USERDATA'"
  cat > "$USERDATA" <<'UD'
#!/bin/bash
for v in 17 16 15; do
  if dnf install -y "postgresql$v"; then dnf install -y "postgresql$v-contrib" || true; break; fi
done
dnf install -y bind-utils || true
touch /var/tmp/mybank-client-ready
UD
  CLIENT_INSTANCE_ID=$(aws ec2 run-instances --region "$AWS_REGION" --image-id "$AMI_ID" --instance-type "$CLIENT_INSTANCE_TYPE" --key-name "$CLIENT_KEY_NAME" \
    --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET1_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" --user-data "file://$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$CLIENT_NAME},{Key=Project,Value=MyBankAuroraWorkshop}]" \
    --query 'Instances[0].InstanceId' --output text)
  persist; ok "Launched $CLIENT_INSTANCE_ID (AMI $AMI_ID)"
  aws ec2 wait instance-running --instance-ids "$CLIENT_INSTANCE_ID" --region "$AWS_REGION"
  CLIENT_IP=$(public_ip "$CLIENT_INSTANCE_ID"); persist
  ok "Running, public IP $CLIENT_IP"

  step "Wait for SSH + PostgreSQL client install (1-3 min)"
  READY=0
  for ((i = 1; i <= 40; i++)); do
    remote -o BatchMode=yes 'test -f /var/tmp/mybank-client-ready' 2>/dev/null && { READY=1; break; }
    sleep 6
  done
  (( READY )) || die "Client not reachable over SSH / not ready after 4 min. Check SG $CLIENT_SG_ID allows 22 from your IP."
  ok "SSH works; $(remote 'psql --version')"
  remote 'command -v pgbench >/dev/null' && ok "pgbench: $(remote 'pgbench --version')" || warn "pgbench missing: on the EC2 run  sudo dnf install -y postgresql17-contrib"

  step "Copy lab files and test the database path from inside the VPC"
  mapfile -t FILES < <(ls -1 ./*.sh ./*.sql ./*.env ./*.csv 2>/dev/null)
  remote 'mkdir -p ~/lab'; scp -q "${SSH_OPTS[@]}" "${FILES[@]}" "ec2-user@$CLIENT_IP:lab/"
  ok "Copied ${#FILES[@]} files to ~/lab"
  remote_test || warn "Check that SG $SG_ID allows 5432 from $CLIENT_SG_ID"

  step "Log in (copy-paste)"
  cmd "ssh -i $CLIENT_KEY_FILE ec2-user@$CLIENT_IP"
  if [[ -n "${PROXY_ENDPOINT:-}" ]]; then NEXT=("bash $0 ssh" "cd lab && bash 10b-proxy-demo.sh check   # on the EC2")
  else NEXT=("bash 10-rds-proxy.sh            # create the proxy (then: bash $0 sync)" "bash $0 ssh"); fi
  lab_next "${NEXT[@]}"
  lab_success "client EC2 $CLIENT_INSTANCE_ID is ready at $CLIENT_IP" ;;
sync)
  require_ip
  mapfile -t FILES < <(ls -1 ./*.sh ./*.sql ./*.env ./*.csv 2>/dev/null)
  remote 'mkdir -p ~/lab'; scp -q "${SSH_OPTS[@]}" "${FILES[@]}" "ec2-user@$CLIENT_IP:lab/"
  ok "Copied ${#FILES[@]} files to ec2-user@$CLIENT_IP:~/lab"
  [[ -f proxy.env ]] && ok "proxy.env included (PROXY_ENDPOINT=$PROXY_ENDPOINT)" || warn "No proxy.env yet — run 10-rds-proxy.sh, then sync again"
  remote_test || true
  lab_next "bash $0 ssh" "cd lab && bash 10b-proxy-demo.sh check   # on the EC2"
  lab_success "lab files synced to the client" ;;
ssh)
  require_ip
  info "Then:  cd lab && bash 10b-proxy-demo.sh check"
  LAB_DONE=1; exec ssh "${SSH_OPTS[@]}" "ec2-user@$CLIENT_IP" ;;
test)
  require_ip; remote_test || die "Database not reachable from the client EC2"
  lab_success "client EC2 reaches the database" ;;
status)
  ID="${CLIENT_INSTANCE_ID:-$(find_instance)}"
  [[ -n "$ID" && "$ID" != None ]] || { ok "No client instance"; lab_success "status shown"; exit 0; }
  aws ec2 describe-instances --instance-ids "$ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress}' --output table
  [[ -n "${CLIENT_IP:-}" ]] && cmd "ssh -i $CLIENT_KEY_FILE ec2-user@$CLIENT_IP"
  lab_success "status shown" ;;
delete)
  [[ -n "${VPC_ID:-}" ]] || { ok "VPC_ID not set; nothing to do"; lab_success "nothing to delete"; exit 0; }
  ID="${CLIENT_INSTANCE_ID:-}"; [[ -n "$ID" && "$ID" != None ]] || ID=$(find_instance)
  if [[ -n "$ID" && "$ID" != None ]] && aws ec2 describe-instances --instance-ids "$ID" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws ec2 terminate-instances --instance-ids "$ID" --region "$AWS_REGION" >/dev/null; ok "Terminating $ID"
    aws ec2 wait instance-terminated --instance-ids "$ID" --region "$AWS_REGION"; ok "Terminated"
  fi
  C_SG=$(find_sg "$CLIENT_SG_NAME")
  if [[ -n "$C_SG" && "$C_SG" != None ]]; then
    for target in "${SG_ID:-}" "${PROXY_SG_ID:-$(find_sg "$PROXY_SG_NAME")}"; do
      [[ -n "$target" && "$target" != None && "$target" != "?" ]] || continue
      aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$target" --protocol tcp --port 5432 --source-group "$C_SG" >/dev/null 2>&1 \
        && ok "Removed client rule from $target" || true
    done
    try "delete SG $C_SG" aws ec2 delete-security-group --group-id "$C_SG" --region "$AWS_REGION"
  fi
  aws ec2 delete-key-pair --key-name "$CLIENT_KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
  rm -f "$CLIENT_KEY_FILE" client.env; ok "Key pair and client.env removed"
  lab_success "client EC2 resources removed" ;;
*) die "Usage: bash $0 {create|sync|ssh|test|status|delete}" ;;
esac
