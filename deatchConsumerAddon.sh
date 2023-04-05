#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Deatch the ODF MS consumer addon from hive

  Requirements:
    1. A ROSA cluster with ODF MS Consumer addon installed.
    2. kubectl, ocm and jq installed.

  USAGE: "./deatachConsumerAddon.sh <clusterID>"

  To install kubectl, ocm & jq refer:
  1. kubectl: ${link[kubectl]}
  2. jq: ${link[jq]}
  3. ocm: ${link[ocm]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi
echo "${Green}Deatach addon script started${EndColor}"

echo -e "\n${Cyan}Scaling down the addon-operator-manager${EndColor}"
kubectl scale deployment addon-operator-manager -n openshift-addon-operator --replicas 0

# removing owner ref from namespace and subscription
echo -e "\n${Cyan}Deleting addoninstance from openshift-storage namespace${EndColor}"
kubectl delete addoninstance addon-instance -n openshift-storage --cascade='orphan'

echo "${Cyan}Patching the addon ocs-consumer to remove finalizers${EndColor}"
kubectl patch addon ocs-consumer -p '{"metadata":{"finalizers":null}}' --type=merge

echo -e "\n${Cyan}Deleting addon ocs-consumer${EndColor}"
kubectl delete addon ocs-consumer --cascade='orphan'

echo -e "\n${Cyan}Scaling down the ocs-osd-deployer${EndColor}"
kubectl scale deployment ocs-osd-controller-manager -n openshift-storage --replicas=0

echo -e "\n${Cyan}Uninstalling consumer addon${EndColor}"

ocm delete /api/clusters_mgmt/v1/clusters/$1/addons/ocs-consumer

while true
do

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$1/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer") | .state')

  echo "${Blue}waiting for addon to be uninstalled current state is ${EndColor}"$state
  if [[ $state == "deleting" ]];
  then
      break
  fi
  sleep 60
done

echo -e "\n${Cyan}Deleting ocs-osd-deployer-csv${EndColor}"
kubectl delete csv $(kubectl get csv -n openshift-storage | grep ocs-osd | awk '{print $1}') -n openshift-storage

while true
do

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$1/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer") | .state')

  echo "${Blue}waiting for addon to be uninstalled current state is ${EndColor}"$state
  if [ -z "$state" ];
  then
      break
  fi
  sleep 60
done

echo -e "\n${Cyan}Uninstalled ocs-consumer addon${EndColor}"

echo -e "\n${Cyan}Deleting addon/ocs-osd-deployer subscription${EndColor}"
kubectl delete subs addon-ocs-consumer -n openshift-storage

echo "${Cyan}Patching the managedocs to remove finalizers${EndColor}"
kubectl patch managedocs managedocs -n openshift-storage -p '{"metadata":{"finalizers":null}}' --type=merge
echo -e "\n${Cyan}Deleting managedocs CR${EndColor}"
kubectl delete managedocs managedocs -n openshift-storage --cascade='orphan'

echo -e "\n${Cyan}Deleting addon deletion configmap${EndColor}"
kubectl delete configmap ocs-consumer -n openshift-storage

# echo -e "\nDeleting addon catalog source"
# kubectl delete catsrc addon-ocs-consumer-catalog -n openshift-storage

echo -e "\n${Cyan}Scaling up the addon-operator-manager${EndColor}"
kubectl scale deployment addon-operator-manager -n openshift-addon-operator --replicas 1
echo "${Green}Deatach addon script completed!${EndColor}"
