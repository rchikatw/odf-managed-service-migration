These files can be used to restore lost provider cluster with having EBS volume.
FreeEBSVolumes.sh -> Remove the osd and mon pods on the provider cluster.
restore_provider.sh -> Restore a ODF MS provider into a new cluster.
restore_consumer.sh -> Update the StorageConsumer id in the status section of StorageCluster CR.

For prerequisite/more details refer help. 
