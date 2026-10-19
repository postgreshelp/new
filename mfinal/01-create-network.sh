#!/usr/bin/env bash
# Lab network: VPC, 3 subnets in 3 AZs, internet gateway + route, S3 gateway endpoint (free; lets Aurora reach S3),
# Aurora SG (5432 from LAB_CIDR + from itself), DB subnet group. IDs are saved to B02-network.env.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Create lab network"

step "Pre-checks"
EXISTING=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters "Name=tag:Name,Values=${NAME_PREFIX}-VPC" --query 'Vpcs[0].VpcId' --output text)
[[ "$EXISTING" == None || -z "$EXISTING" ]] || die "A VPC named ${NAME_PREFIX}-VPC already exists ($EXISTING). Reuse it (keep B02-network.env) or remove it: bash 90-teardown.sh"
aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" >/dev/null 2>&1 \
  && die "DB subnet group $DB_SUBNET_GROUP already exists. Remove it first: bash 90-teardown.sh"
mapfile -t AZS < <(aws ec2 describe-availability-zones --region "$AWS_REGION" --filters Name=state,Values=available \
  --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | head -n 3)
((${#AZS[@]} == 3)) || die "Need three available AZs; found ${#AZS[@]}"
ok "No existing lab network; AZs: ${AZS[*]}"
info "VPC $VPC_CIDR | subnets $SUBNET1_CIDR $SUBNET2_CIDR $SUBNET3_CIDR | 5432 open to ${LAB_CIDR:-nobody}"
confirm "Create the lab network"

TAGS() { printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=MyBankAuroraWorkshop}]' "$1" "$2"; }
STATE_VARS=(AWS_REGION VPC_ID IGW_ID RT_ID SG_ID S3_ENDPOINT_ID DB_SUBNET_GROUP SUBNET1_ID SUBNET2_ID SUBNET3_ID)
VPC_ID=""; IGW_ID=""; RT_ID=""; SG_ID=""; S3_ENDPOINT_ID=""; SUBNET1_ID=""; SUBNET2_ID=""; SUBNET3_ID=""
persist() { save_env B02-network.env "${STATE_VARS[@]}"; }   # saved after every step, so teardown can clean a half-built network

step "VPC"
VPC_ID=$(aws ec2 create-vpc --region "$AWS_REGION" --cidr-block "$VPC_CIDR" --tag-specifications "$(TAGS vpc "${NAME_PREFIX}-VPC")" --query Vpc.VpcId --output text); persist
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$AWS_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
ok "VPC $VPC_ID (DNS support + hostnames on)"

step "Subnets (one per AZ)"
CIDRS=("$SUBNET1_CIDR" "$SUBNET2_CIDR" "$SUBNET3_CIDR"); SUBNET_IDS=()
for i in 0 1 2; do
  sid=$(aws ec2 create-subnet --region "$AWS_REGION" --vpc-id "$VPC_ID" --cidr-block "${CIDRS[$i]}" --availability-zone "${AZS[$i]}" \
    --tag-specifications "$(TAGS subnet "${NAME_PREFIX}-SN-0$((i+1))")" --query Subnet.SubnetId --output text)
  SUBNET_IDS+=("$sid"); printf -v "SUBNET$((i+1))_ID" '%s' "$sid"; persist
  ok "Subnet $sid  ${CIDRS[$i]}  ${AZS[$i]}"
done

step "Internet gateway and route table"
IGW_ID=$(aws ec2 create-internet-gateway --region "$AWS_REGION" --tag-specifications "$(TAGS internet-gateway "${NAME_PREFIX}-IGW")" --query InternetGateway.InternetGatewayId --output text); persist
aws ec2 attach-internet-gateway --region "$AWS_REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
RT_ID=$(aws ec2 create-route-table --region "$AWS_REGION" --vpc-id "$VPC_ID" --tag-specifications "$(TAGS route-table "${NAME_PREFIX}-RT")" --query RouteTable.RouteTableId --output text); persist
aws ec2 create-route --region "$AWS_REGION" --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
for sid in "${SUBNET_IDS[@]}"; do aws ec2 associate-route-table --region "$AWS_REGION" --route-table-id "$RT_ID" --subnet-id "$sid" >/dev/null; done
ok "IGW $IGW_ID attached; route table $RT_ID (0.0.0.0/0 -> IGW) on all 3 subnets"

step "S3 gateway endpoint (free; Aurora reaches S3 for aws_s3 import/export even without public IPs)"
S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint --region "$AWS_REGION" --vpc-id "$VPC_ID" --vpc-endpoint-type Gateway \
  --service-name "com.amazonaws.${AWS_REGION}.s3" --route-table-ids "$RT_ID" \
  --tag-specifications "$(TAGS vpc-endpoint "${NAME_PREFIX}-S3-EP")" --query VpcEndpoint.VpcEndpointId --output text); persist
ok "S3 endpoint $S3_ENDPOINT_ID"

step "Aurora security group"
SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$SG_NAME" --description 'MyBank Aurora workshop database SG' \
  --vpc-id "$VPC_ID" --tag-specifications "$(TAGS security-group "$SG_NAME")" --query GroupId --output text); persist
ok "SG $SG_ID ($SG_NAME)"
[[ -n "${LAB_CIDR:-}" ]] && sg_allow "$SG_ID" 5432 --cidr "$LAB_CIDR"
sg_allow "$SG_ID" 5432 --source-group "$SG_ID"    # anything inside this SG can reach Aurora

step "DB subnet group"
aws rds create-db-subnet-group --region "$AWS_REGION" --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description 'MyBank Aurora workshop subnet group' --subnet-ids "${SUBNET_IDS[@]}" \
  --tags Key=Project,Value=MyBankAuroraWorkshop >/dev/null
persist
ok "DB subnet group $DB_SUBNET_GROUP (3 subnets / 3 AZs)"

step "Verify"
N=$(aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$AWS_REGION" --query 'length(DBSubnetGroups[0].Subnets)' --output text)
[[ "$N" == 3 ]] && ok "Subnet group has 3 subnets" || die "Subnet group has $N subnets (expected 3)"
ok "State saved to B02-network.env (env.sh loads it automatically)"

lab_next "bash 00-preflight.sh        # optional re-check" "bash 02-create-cluster.sh"
lab_success "network created in $VPC_ID"
