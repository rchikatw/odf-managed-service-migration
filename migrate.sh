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

#TODO: -r/-m
#TODO: MTSRE can use external Cluster ID to login into consumerCluster, we won't need account in customers ocm org then

cleanup

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1}" == "-d" ]]; then
  validate "kubectl" "curl" "ocm" "jq" "yq" "aws" "rosa"
else
  validate "ocm-backplane" "kubectl" "curl" "ocm" "jq" "yq" "aws" "rosa"
fi

echo -e "\nEnter the clusterID of backup cluster: "
read backupClusterID

loginCluster $1 "$backupClusterID"

echo -e "\nValidating if all consumer clusters are above OCP 4.11 and the pods using the PVC are scaled down"
consumers=( $(kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}') )
for consumer in $consumers
do
  consumerClusterID=$(ocm list clusters --columns ID,name,externalID | grep ${consumer#*-} | awk '{ print $1; exit}')
  loginCluster $1 "$consumerClusterID"

  version=$(kubectl get clusterversion version -oyaml | yq '.status .desired .version')
  if [[ "$version" < "4.11" ]]; then
  echo "Error: Please update the consumer cluster "$consumerClusterID" to >=4.11.z"
  exit 1
  fi

  volumeAttachments=( $(kubectl get volumeattachment -n openshift-storage | grep 'rbd.csi.ceph.com\|cephfs.csi.ceph.com'| awk '{print $3}') )
  boundPVs=()
  for volumeAttachment in "${volumeAttachments[@]}"
  do
    boundPVs[${#boundPVs[@]}]=${volumeAttachment}
  done
  if [[ "${#boundPVs[@]}" > "0" ]]; then
    echo -e "\nThere are still PVC which are using by pods please scale down the application pod and re-run the script\n"
    echo -e "Cluster ID: "$consumerClusterID
    printf "%s\n" "${boundPVs[@]}"
    exit
  fi
done

echo "Validation Complete!"

loginCluster $1 "$backupClusterID"

echo -e "\nTaking a backup of resouces required for backup"
sh ./backupResources.sh
echo "Backup Complete!"

echo -e "\nScaling down the rook-ceph pods connected to the EBS Volumes"
sh ./freeEBSVolumes.sh
echo "Scaling down Complete!"

echo -e "\nEnter the clusterID of the new cluster:"
read restoreClusterID

loginCluster $1 "$restoreClusterID"

echo -e "\nMigrating to the new Provider"
sh ./restoreProvider.sh
echo "Migration of Provider Complete!"

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
  #TODO: decide when we want to deatach addon
  sh ./deatchConsumerAddon.sh "$consumerClusterID"
  echo "ConsumerClusterID: "$consumerClusterID " storageConsumerUID: " ${storageConsumerUID[$consumer]}
  sh ./migrateConsumer.sh "$storageProviderEndpoint" "${storageConsumerUID[$consumer]}" "$consumerClusterID"
  # sh ./restoreConsumer.sh "$storageProviderEndpoint" "${storageConsumerUID[$consumer]}"
done

loginCluster $1 "$restoreClusterID"
sh ./updateEBSVolumeTags.sh

echo -e "\nDeleting the old/backup cluster"
clusterName=$(ocm list clusters | grep ${backupClusterID} | awk '{print $2}')
serviceId=$(rosa list services | grep ${clusterName} | awk '{print $1}')

echo -e "\nDeletion of Service is started"
rosa delete service --id=$serviceId -y

while true
do

  state=$(rosa list service | grep $serviceId | awk '{print $3}')

  echo "waiting for service to be deleted current state is "$state
  if [[ $state == "deleting service" ]];
  then
      break
  fi
  sleep 60
done

loginCluster $1 "$backupClusterID"
kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl patch storageconsumer -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage
kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl delete storageconsumer -n openshift-storage
kubectl get storagesystem -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl patch storagesystem -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage
kubectl get storagecluster -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl patch storagecluster -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage

echo -e "\nDeletion of Old Service cluster is started, It will take some to delete the service."

cleanup
echo -e "\nMigration Process completed!"
