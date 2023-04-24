## ODF Managed Service Migration scripts.
- backupResources.sh -> Takes the backup of required resources for restoring provider cluster or retrives it from s3 bucket.
- freeEBSVolumes.sh -> Scale down the osd and mon pods on the provider cluster.
- restoreProvider.sh -> Restore a ODF MS provider into a new cluster.
- deatchConsumerAddon.sh -> Deatch the ODF MS consumer addon from hive.
- updateEBSVolumes.sh -> Update the aws ebs volume tags for osd's and mon's from provider cluster and change the storageClass to gp3.
- migrateConsumer.sh -> Migrates the from old cluster to new cluster.
- migrate.sh -> Will run all necessary script to migrate cluster.

---
## Prerequisite
### Have the following cli tools installed:
- [kubectl](https://kubernetes.io/docs/tasks/tools/) > 1.24
- [jq](https://www.cyberithub.com/how-to-install-jq-json-processor-on-rhel-centos-7-8/) >= 1.6
- [yq](https://www.cyberithub.com/how-to-install-yq-command-line-tool-on-linux-in-5-easy-steps/) >= 4.3
- [ocm](https://console.redhat.com/openshift/downloads)
- [aws](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [ocm-backplane](https://gitlab.cee.redhat.com/service/backplane-cli)
- [rosa](https://console.redhat.com/openshift/downloads)

### Configuration for New Agent/Provider
- New ROSA cluster should be in the same VPC
- The ROSA version for new cluster should be 4.12
- New ROSA cluster shuld be multi-az, We don't support migration into single az clusters
- The ManagedFusion Agent and Offering should be installed before running the migration
- The Offering should be installed on `fusion-storage` namespace
- New DataFoundation offering should of the same size as old Provider
- New DataFoundation offering should have the same onBoardingValidationKey

### Cluster ID for the following cluster:
- Backup/Old Cluster
- Migrated/New Cluster

### AWS permissions required

### User in customers organization for ocm API's

---
## Steps to migrate provider
- Clone the github repository
- Run script using ./migrate.sh -provider <oldClusterID> <newClusterID> -d [env for consumer addon [-dev]/[-qe]], When you have dev addon installed ex: 
```
 ./migrate.sh -provider <oldClusterID> <newClusterID> -d -dev
```
- If you dont pass env for addon the script will consider as prod addon.
- If we have access to ocm-backplane, we do not require the -d option, we can run the script as:
```
    ./migrate.sh -provider <oldClusterID> <newClusterID>
```
- After the provider migration completed, The script will print the commands to run for each consumer.
- Run them one after the other or in separate terminals to speed up the migration. The template for consumer migration command would be:
```
  ./migrate.sh -consumer <ConsumerClusterID> <StorageProviderEndpoint> <new UID for storageconsumer from provider> [-d] [-dev/-qe]
```

- After completion of the Consumer script, scale up the applications/deployments on the consumer side and verify that we have the expected data.
---
> **Note** Running this script requires around an hour of downtime for cluster.


