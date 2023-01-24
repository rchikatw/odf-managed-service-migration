## ODF Managed Service Migration scripts.
- FreeEBSVolumes.sh -> Scale down the osd and mon pods on the provider cluster.
- restore_provider.sh -> Restore a ODF MS provider into a new cluster.
- restore_consumer.sh -> Update the StorageConsumer id and StorageProviderEndpoint in the StorageCluster CR.
- backup_resources.sh -> Takes the backup of required resources for restoring provider cluster.
- updateEBSVolumeTags.sh -> Update the aws ebs volume tags for osd's and mon's from provider cluster.
- deatch_addon.sh -> Deatch the ODF MS consumer addon from hive.

---
## Steps to migrate provider
