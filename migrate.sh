#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Meta script that runs all the required script for migration.

  Requirements:
    1. kubectl, ocm installed.
    2. clusterID for the clusters

  USAGE: "./migrate.sh [-d] [env for consumer addon [-dev]/[-qe]]"

  Note:
  1. Use -d when not using ocm-backplane
  2. Env for consumer addon by default is production, use -dev/-qe for testing

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

if [[ "${2}" != "-dev" ]] && [[ "${2}" != "-qe" ]] && [[ "${2}" != "" ]]; then
  usage
  exit 0
fi

echo -e "\n${BoldCyan}Enter the clusterID of backup cluster: ${EndColor}"
read backupClusterID

loginCluster $1 "$backupClusterID"

echo -e "\n${Cyan}Validating if all consumer clusters are above OCP 4.11 and the pods using the PVC are scaled down${EndColor}"
consumers=( $(kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}') )
for consumer in $consumers
do
  consumerClusterID=$(ocm list clusters --columns ID,name,externalID | grep ${consumer#*-} | awk '{ print $1; exit}')
  loginCluster $1 "$consumerClusterID"

  version=$(kubectl get clusterversion version -oyaml | yq '.status .desired .version')
  if [[ "$version" < "4.11" ]]; then
  echo -e "${Red}Error: Please update the consumer cluster "$consumerClusterID" to >=4.11.z${EndColor}"
  exit 1
  fi

  volumeAttachments=( $(kubectl get volumeattachment -n openshift-storage | grep 'rbd.csi.ceph.com\|cephfs.csi.ceph.com'| awk '{print $3}') )
  boundPVs=()
  for volumeAttachment in "${volumeAttachments[@]}"
  do
    boundPVs[${#boundPVs[@]}]=${volumeAttachment}
  done
  if [[ "${#boundPVs[@]}" > "0" ]]; then
    echo -e "\n${Red}On Consumer with ClusterID: ${EndColor}"$consumerClusterID"${Red} We still have some applications using the PVC, Please scale down/delete the pods and re-run the script.\nPVC's being used are: ${EndColor}"
    printf "%s\n" "${boundPVs[@]}"
    exit
  fi
done

echo -e "${Cyan}Validation Complete!${EndColor}"

loginCluster $1 "$backupClusterID"

sh ./backupResources.sh

sh ./freeEBSVolumes.sh

echo -e "\n${BoldCyan}Enter the clusterID of the new cluster:${EndColor}"
read restoreClusterID

loginCluster $1 "$restoreClusterID"

sh ./restoreProvider.sh

unset storageConsumerUID
declare -A storageConsumerUID

consumers=`ls  backup/storageconsumers`
storageProviderEndpoint=$(kubectl get StorageCluster ocs-storagecluster -n ${dfOfferingNamespace} -o json | jq -r '.status .storageProviderEndpoint')
for entry in $consumers
do
  consumerName=$(cat backup/storageconsumers/$entry | jq -r '.metadata .name')
  uid=$(kubectl get storageconsumer ${consumerName} -n ${dfOfferingNamespace} -o json | jq -r '.metadata .uid')
  storageConsumerUID[$consumerName]=$uid
done

for consumer in "${!storageConsumerUID[@]}"
do
  consumerClusterID=$(ocm list clusters --columns ID,name,externalID | grep ${consumer#*-} | awk '{ print $1; exit}')

  loginCluster $1 "$consumerClusterID"
  #TODO: decide when we want to deatach addon
  sh ./deatchConsumerAddon.sh "$consumerClusterID" "$2"
  echo -e "ConsumerClusterID: "$consumerClusterID " storageConsumerUID: " ${storageConsumerUID[$consumer]}
  sh ./migrateConsumer.sh "$storageProviderEndpoint" "${storageConsumerUID[$consumer]}" "$consumerClusterID"
  # sh ./restoreConsumer.sh "$storageProviderEndpoint" "${storageConsumerUID[$consumer]}"
done

loginCluster $1 "$restoreClusterID"
sh ./updateEBSVolumeTags.sh

echo -e "\n${Cyan}Deleting the old/backup cluster${EndColor}"
clusterName=$(ocm list clusters | grep ${backupClusterID} | awk '{print $2}')
serviceId=$(rosa list services | grep ${clusterName} | awk '{print $1}')

echo -e "\n${Cyan}Deletion of Service is started${EndColor}"

rosa delete service --id=$serviceId -y
sleep 60
while true
do

  state=$(rosa list service | grep $serviceId | awk '{print $3" "$4}')

  echo -e "${Blue}waiting for service to be deleted current state is ${EndColor}"$state
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

echo -e "\n${Green}Deletion of Old Provider Service cluster is started, the service will be deleted soon.${EndColor}"

cleanup
echo -e "\n${Green}Migration Process completed!${EndColor}"
