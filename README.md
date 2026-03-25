
aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name ${DBClusterParameterGroup} --region ${REGION} --source user --query 'Parameters[].{ParameterName:ParameterName,ParameterValue:ParameterValue,ApplyMethod:ApplyMethod}' > old-version.json

Risks for Not upgrading:
• End of Support. No security patches, bug fixes were released.
• Additional cost for Extended Support
• Cannot opt for io-optimized instances
• Cannot use the latest features and extensions
Risks for upgrading to v14
• Index corruption up to 14.3
• Before upgrading, the replication slots must be dropped, and the replication must be rebuilt from scratch.
• If the statistics are not updated, performance problems may arise.
• If you don't manually update the extensions, they can stop functioning correctly.
• Python code,.net code, backend schedulers, and applications should all support and work with the updated version.
• Query plans gets changed which sometimes degrades the performance
Once you've upgraded and started adding new data, it's very challenging to go back to the old version without losing that
new data
