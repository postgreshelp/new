# new

aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name ${DBClusterParameterGroup} --region ${REGION} --source user --query 'Parameters[].{ParameterName:ParameterName,ParameterValue:ParameterValue,ApplyMethod:ApplyMethod}' > old-version.json
