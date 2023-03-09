#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Meta script that runs all the required script for migration.

  Requirements:
    1. kubectl, ocm installed.
    2. clusterID for the clusters

  USAGE: "./migrate.sh [-d]"

  Note: Use -d when not using ocm-backplane

  To install kubectl & ocm refer:
  1. kubectl: ${link[kubectl]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1}" == "-d" ]]; then
  validate "kubectl" "curl" "ocm" "rosa" "jq" "yq" "aws"
else
  validate "ocm-backplane" "kubectl" "curl" "ocm" "rosa" "jq" "yq" "aws"
fi

echo -e "\nEnter the clusterID of backup cluster: "
read backupClusterID

loginCluster $1 "$backupClusterID"

sh ./backup_resources.sh "incluster"

sh ./freeEBSVolumes.sh

echo -e "\nEnter the clusterID of the new cluster:"
read restoreClusterID

loginCluster $1 "$restoreClusterID"

sh ./restore_provider.sh

unset storageConsumerUID
declare -A storageConsumerUID

consumers=`ls  backup/storageconsumers`
storageProviderEndpoint=$(kubectl get StorageCluster ocs-storagecluster -n openshift-storage -o json | jq -r '.status .storageProviderEndpoint')
for entry in $consumers
do
  consumerName=$(cat backup/storageconsumers/$entry | jq -r '.metadata .name')
  uid=$(kubectl get storageconsumer ${consumerName} -n openshift-storage -o json | jq -r '.metadata .uid')
  storageConsumerUID[$consumerName]=$uid
done

for consumer in "${!storageConsumerUID[@]}"
do
  consumerClusterID=$(ocm list clusters --columns ID,name,externalID | grep ${consumer#*-} | awk '{ print $1; exit}')

  loginCluster $1 "$consumerClusterID"
  sh ./deatch_addon.sh "$consumerClusterID"
  sh ./restore_consumer.sh "$storageProviderEndpoint" "${storageConsumerUID[$consumer]}"
done

loginCluster $1 "$restoreClusterID"
sh ./updateEBSVolumeTags.sh

cleanup
