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

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 1
fi

validateConsumers() {
  loginCluster $1 $2

  echo -e "\n${Cyan}Validating if all consumer clusters are above OCP 4.11 and the pods using the PVC are scaled down${EndColor}"
  consumers=( $(kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}') )
  for consumer in $consumers
  do
    consumerClusterID=$(ocm list clusters --columns ID,name,externalID | grep ${consumer#*-} | awk '{ print $1; exit}')
    loginCluster "$consumerClusterID" $2

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
      echo -e "\n${Red}On Consumer with ClusterID: ${EndColor}"$consumerClusterID"${Red} We still have some applications using the PVC, Please scale down/delete the pods and re-run the script.\nPVC's being used are:${EndColor}"
      printf "%s\n" "${boundPVs[@]}"
      exit
    fi
  done

  echo -e "${Cyan}Validation Complete!${EndColor}"
}

providerMigration() {

  if [ -z "${1}" ] || [ -z "${2}" ]; then
    usage
    exit 0
  fi

  if [[ "${3}" == "-d" ]]; then
    validate "kubectl" "curl" "ocm" "jq" "yq" "aws" "rosa"
  else
    validate "ocm-backplane" "kubectl" "curl" "ocm" "jq" "yq" "aws" "rosa"
  fi

  if [[ "${4}" != "-dev" ]] && [[ "${4}" != "-qe" ]] && [[ "${4}" != "" ]]; then
    usage
    exit 0
  fi

  validateConsumers $1 $3

  sh ./backupResources.sh $1 $3 || exit 1

  sh ./freeEBSVolumes.sh $1 $3 || exit 1

  sh ./restoreProvider.sh $2 $3 || exit 1

  sh ./updateEBSVolumeTags.sh $2 $3 || exit 1

  echo -e "\n${Cyan}Deleting the old/backup cluster${EndColor}"
  clusterName=$(ocm list clusters | grep $1 | awk '{print $2}')
  serviceId=$(rosa list services | grep ${clusterName} | awk '{print $1}')

  echo -e "\n${Cyan}Deletion of Service is started${EndColor}"
  rosa delete service --id=$serviceId -y
  sleep 20

  loginCluster $1 $3
  #TODO: update to check if configmap is present
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

  kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl patch storageconsumer -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage
  kubectl get storageconsumer -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl delete storageconsumer -n openshift-storage
  kubectl get storagesystem -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl patch storagesystem -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage
  kubectl get storagecluster -n openshift-storage --no-headers | awk '{print $1}' | xargs kubectl patch storagecluster -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage

  echo -e "\n${Green}Deletion of Old Provider Service cluster is started, the service will be deleted soon.${EndColor}"

  echo -e "\n${Green}Run the following commands in new terminal, sequentially/parellel to migrate the consumers.${EndColor}"
  
  loginCluster $2 $3

  consumers=`ls  backup/storageconsumers`
  storageProviderEndpoint=$(kubectl get StorageCluster ocs-storagecluster -n ${dfOfferingNamespace} -o json | jq -r '.status .storageProviderEndpoint')
  for entry in $consumers
  do
    consumerName=$(cat backup/storageconsumers/$entry | jq -r '.metadata .name')
    uid=$(kubectl get storageconsumer ${consumerName} -n ${dfOfferingNamespace} -o json | jq -r '.metadata .uid')
    consumerClusterID=$(ocm list clusters --columns ID,name,externalID | grep ${consumerName#*-} | awk '{ print $1; exit}')

    echo -e "\n${Cyan}For Consumer with ClusterID${EndColor}: "$consumerClusterID
    echo -e "\n./migrate.sh -consumer "$consumerClusterID" "$storageProviderEndpoint" "${uid}" "$3" "$4"\n\n"
  done

}

consumerMigration() {
  
  if [ -z "${1}" ] || [ -z "${2}" ] || [ -z "${3}" ]; then
    usage
    exit 1
  fi

  if [[ "${4}" == "-d" ]]; then
    validate "kubectl" "curl" "ocm" "jq" "yq"
  else
    validate "ocm-backplane" "kubectl" "curl" "ocm" "jq" "yq"
  fi

  if [[ "${5}" != "-dev" ]] && [[ "${5}" != "-qe" ]] && [[ "${5}" != "" ]]; then
    usage
    exit 1
  fi

  sh ./deatchConsumerAddon.sh $1 $5 $4 || exit 1
  sh ./migrateConsumer.sh $2 $3 $1 $4 || exit 1
}

if [[ "${1}" == "-provider" ]]; then
  providerMigration $2 $3 $4 $5
elif [[ "${1}" == "-consumer" ]]; then
  consumerMigration $2 $3 $4 $5 $6
else
  usage
  exit 1
fi

echo -e "\n${Green}Migration Process completed!${EndColor}"
