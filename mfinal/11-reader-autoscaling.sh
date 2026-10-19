#!/usr/bin/env bash
# Aurora reader auto scaling: target tracking on average reader CPU.
#   bash 11-reader-autoscaling.sh            # configure (min/max/target from env.sh) and verify it registered
#   bash 11-reader-autoscaling.sh remove     # delete policy + scalable target (auto-created readers are then yours to delete)
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh
ACTION="${1:-configure}"
lab_init "Reader auto scaling: $ACTION"
cluster_exists || die "Cluster $CLUSTER_ID not found"
RESOURCE_ID="cluster:${CLUSTER_ID}"; POLICY_NAME="${CLUSTER_ID}-reader-cpu-target"
AS=(--service-namespace rds --scalable-dimension rds:cluster:ReadReplicaCount --resource-id "$RESOURCE_ID" --region "$AWS_REGION")

if [[ "$ACTION" == remove ]]; then
  confirm "Remove auto scaling policy and scalable target"
  try "delete scaling policy" aws application-autoscaling delete-scaling-policy "${AS[@]}" --policy-name "$POLICY_NAME"
  try "deregister scalable target" aws application-autoscaling deregister-scalable-target "${AS[@]}"
  info "Readers created by auto scaling are named application-autoscaling-*; they stay until you delete them."
  lab_success "auto scaling removed"; exit 0
fi

[[ "$ASG_MIN_READERS" =~ ^[0-9]+$ && "$ASG_MAX_READERS" =~ ^[0-9]+$ ]] && (( ASG_MAX_READERS >= ASG_MIN_READERS )) \
  || die "Check ASG_MIN_READERS/ASG_MAX_READERS in env.sh"
step "Plan"
info "Readers: min $ASG_MIN_READERS, max $ASG_MAX_READERS. Target: average reader CPU ${ASG_TARGET_CPU}%."
info "Scale-out cooldown 300s, scale-in cooldown 300s. Auto readers use the cluster's class ($DB_INSTANCE_CLASS) and are billable."
info "Current readers: $(current_readers | tr '\n' ' ')"
confirm "Configure reader auto scaling"

step "Register + policy"
aws application-autoscaling register-scalable-target "${AS[@]}" --min-capacity "$ASG_MIN_READERS" --max-capacity "$ASG_MAX_READERS" >/dev/null
ok "Scalable target registered ($RESOURCE_ID, $ASG_MIN_READERS..$ASG_MAX_READERS readers)"
aws application-autoscaling put-scaling-policy "${AS[@]}" --policy-name "$POLICY_NAME" --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "PredefinedMetricSpecification={PredefinedMetricType=RDSReaderAverageCPUUtilization},TargetValue=${ASG_TARGET_CPU},ScaleOutCooldown=300,ScaleInCooldown=300" >/dev/null
ok "Target tracking policy $POLICY_NAME created"

step "Verify"
GOT=$(aws application-autoscaling describe-scaling-policies --service-namespace rds --resource-id "$RESOURCE_ID" --region "$AWS_REGION" \
  --query "ScalingPolicies[?PolicyName=='$POLICY_NAME'].TargetTrackingScalingPolicyConfiguration.TargetValue | [0]" --output text)
ALARMS=$(aws application-autoscaling describe-scaling-policies --service-namespace rds --resource-id "$RESOURCE_ID" --region "$AWS_REGION" \
  --query "ScalingPolicies[?PolicyName=='$POLICY_NAME'].Alarms[].AlarmName" --output text | wc -w | tr -d ' ')
[[ "${GOT%.*}" == "$ASG_TARGET_CPU" ]] && ok "Policy active, target ${GOT}% CPU" || die "Policy not found after creation"
ok "AWS created $ALARMS CloudWatch alarm(s) (scale-out + scale-in) that drive the policy"
info "Configured is not the same as scaled: nothing happens until reader CPU stays above ${ASG_TARGET_CPU}%."

lab_next "on client EC2:  bash 11b-autoscale-load.sh load    # generate reader CPU" \
         "on laptop:      bash 11b-autoscale-load.sh watch   # see a new reader appear"
lab_success "reader auto scaling configured (target ${ASG_TARGET_CPU}% CPU, $ASG_MIN_READERS-$ASG_MAX_READERS readers)"
