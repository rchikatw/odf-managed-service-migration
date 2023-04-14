## ODF Managed Service Migration scripts.
- backupResources.sh -> Takes the backup of required resources for restoring provider cluster or retrives it from s3 bucket.
- freeEBSVolumes.sh -> Scale down the osd and mon pods on the provider cluster.
- restoreProvider.sh -> Restore a ODF MS provider into a new cluster.
- deatchConsumerAddon.sh -> Deatch the ODF MS consumer addon from hive.
- updateEBSVolumeTags.sh -> Update the aws ebs volume tags for osd's and mon's from provider cluster.
- migrateConsumer.sh -> Migrates the from old cluster to new cluster.
- migrate.sh -> Will run all necessary script to migrate cluster.

---
## Prerequisite
### Have the following cli tools installed:
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [curl](https://curl.se/download.html)
- [jq](https://www.cyberithub.com/how-to-install-jq-json-processor-on-rhel-centos-7-8/)
- [yq](https://www.cyberithub.com/how-to-install-yq-command-line-tool-on-linux-in-5-easy-steps/)
- [ocm](https://console.redhat.com/openshift/downloads)
- [aws](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [ocm-backplane](https://gitlab.cee.redhat.com/service/backplane-cli)
- [rosa](https://console.redhat.com/openshift/downloads)

### Cluster ID for the following cluster:
- Backup/Old Cluster
- Migrated/New Cluster

### AWS permissions required

### User in customers organization for ocm API's

---
## Steps to migrate provider
- Clone the github repository
- Run script using ./migrate.sh -d [env for consumer addon [-dev]/[-qe]], When you have dev addon installed ex: 
```
 ./migrate.sh -d -dev
```

- Script will require cluster id for Old/Backup cluster and restore/migrated cluster.

---
> **Note** Running this script requires around an hour of downtime for cluster.


