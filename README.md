## ODF Managed Service Migration scripts.
- backup_resources.sh -> Takes the backup of required resources for restoring provider cluster or retrives it from s3 bucket.
- freeEBSVolumes.sh -> Scale down the osd and mon pods on the provider cluster.
- restore_provider.sh -> Restore a ODF MS provider into a new cluster.
- deatch_addon.sh -> Deatch the ODF MS consumer addon from hive.
- restore_consumer.sh -> Update the StorageConsumer id and StorageProviderEndpoint in the StorageCluster CR.
- updateEBSVolumeTags.sh -> Update the aws ebs volume tags for osd's and mon's from provider cluster.
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

### Cluster ID for the following cluster:
- Backup/Old Cluster
- Migrated/New Cluster

### AWS permissions required

### User in customers organization for ocm API's

---
## Steps to migrate provider
