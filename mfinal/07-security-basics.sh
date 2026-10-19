#!/usr/bin/env bash
# Read-only: encryption, public access, SG rules, TLS in use, roles inside the DB.
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
lab_init "Security basics (read-only)"
need_endpoints

step "Storage encryption and IAM auth"
read -r ENC KMS IAMAUTH < <(cq 'DBClusters[0].[StorageEncrypted,KmsKeyId,IAMDatabaseAuthenticationEnabled]')
[[ "$ENC" == True ]] && ok "Storage encrypted at rest (KMS key: ${KMS##*/})" || warn "Storage NOT encrypted (can't be enabled later; needs snapshot + restore)"
info "IAM database authentication: $IAMAUTH"

step "Network exposure"
while IFS= read -r i; do
  [[ -n "$i" ]] || continue
  printf '  %-28s publicly accessible: %s\n' "$i" "$(iq 'DBInstances[0].PubliclyAccessible' "$i")"
done < <(cluster_instances)
for sg in $(cq 'DBClusters[0].VpcSecurityGroups[].VpcSecurityGroupId'); do
  info "Inbound rules on $sg:"
  aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" --region "$AWS_REGION" \
    --query 'SecurityGroupRules[?IsEgress==`false`].{Proto:IpProtocol,Port:FromPort,FromCidr:CidrIpv4,FromSG:ReferencedGroupInfo.GroupId}' --output table
done
info "Lab mode allows 5432 from ${LAB_CIDR:-?}. In production: private subnets, SG-to-SG rules only."

step "Inside the database"
if can_sql; then
  ok "This session uses TLS: $(sql "$CLUSTER_WRITER" "select case when ssl then 'yes, '||version else 'NO' end from pg_stat_ssl where pid=pg_backend_pid()")"
  info "Is the master user a real superuser? $(sql "$CLUSTER_WRITER" "select rolsuper from pg_roles where rolname=current_user") (Aurora: no; it gets rds_superuser)"
  info "Roles granted to $PGUSER: $(sql "$CLUSTER_WRITER" "select string_agg(b.rolname, ', ') from pg_auth_members m join pg_roles b on b.oid=m.roleid join pg_roles u on u.oid=m.member where u.rolname=current_user")"
  info "rds.force_ssl = $(sql "$CLUSTER_WRITER" "show rds.force_ssl")"
else
  warn "Set PGPASSWORD to run the in-database checks; or in psql:"; psql_cmd "$CLUSTER_WRITER"
  cmd "select ssl, version from pg_stat_ssl where pid = pg_backend_pid();"
fi

lab_next "bash 08-monitoring.sh"
lab_success "security review shown"
