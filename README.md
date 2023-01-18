## These files can be used to restore lost provider cluster with having EBS volume.
- FreeEBSVolumes.sh -> Remove the osd and mon pods on the provider cluster.
- restore_provider.sh -> Restore a ODF MS provider into a new cluster.
- restore_consumer.sh -> Update the StorageConsumer id in the status section of StorageCluster CR.
- backup_resource.sh -> Takes the backup of required resources for restoring provider cluster.
- updateTags.sh -> Used to update the aws ebs volume tags.
