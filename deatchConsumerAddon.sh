#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Deatch the ODF MS consumer addon from hive

  Requirements:
    1. A ROSA cluster with ODF MS Consumer addon installed.
    2. kubectl: ${link[kubectl]}
    3. jq: ${link[jq]}
    4. ocm: ${link[ocm]}

  USAGE: "./deatachConsumerAddon.sh <ConsumerClusterID> [env for consumer addon [-dev]/[-qe]] [-d]"

  Note:
  1. Use -d when not using ocm-backplane
  2. Env for consumer addon by default is production, use -dev/-qe for testing

EOF
}

if [ -z "${1}" ]; then
  usage
  exit 1
fi

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 1
fi

if [[ "${2}" != "-dev" ]] && [[ "${2}" != "-qe" ]] && [[ "${2}" != "" ]]; then
  usage
  exit 1
fi

loginCluster $1 $3 $4

echo -e "${Green}Deatach addon script started${EndColor}"

echo -e "\n${Cyan}Scaling down the addon-operator-manager${EndColor}"
kubectl scale deployment addon-operator-manager -n openshift-addon-operator --replicas 0

# removing owner ref from namespace and subscription
echo -e "\n${Cyan}Deleting addoninstance from openshift-storage namespace${EndColor}"
kubectl delete addoninstance addon-instance -n openshift-storage --cascade='orphan'

echo -e "${Cyan}Patching the addon ocs-consumer$2 to remove finalizers${EndColor}"
kubectl patch addon ocs-consumer$2 -p '{"metadata":{"finalizers":null}}' --type=merge

echo -e "\n${Cyan}Deleting addon ocs-consumer$2 ${EndColor}"
kubectl delete addon ocs-consumer$2 --cascade='orphan'

echo -e "\n${Cyan}Scaling down the ocs-osd-deployer${EndColor}"
kubectl scale deployment ocs-osd-controller-manager -n openshift-storage --replicas=0

echo -e "\n${Cyan}Uninstalling consumer addon${EndColor}"

ocm delete /api/clusters_mgmt/v1/clusters/$1/addons/ocs-consumer$2

while true
do
  state=$(ocm get /api/clusters_mgmt/v1/clusters/$1/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer'$2'") | .state')

  echo -e "${Blue}waiting for addon to be uninstalled current state is ${EndColor}"$state
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

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$1/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer'$2'") | .state')

  echo -e "${Blue}waiting for addon to be uninstalled current state is ${EndColor}"$state
  if [ -z "$state" ];
  then
      break
  fi
  sleep 60
done

echo -e "\n${Cyan}Uninstalled ocs-consumer$2 addon${EndColor}"

echo -e "\n${Cyan}Deleting addon subscription${EndColor}"
kubectl delete subs addon-ocs-consumer$2 -n openshift-storage

echo -e "${Cyan}Patching the managedocs to remove finalizers${EndColor}"
kubectl patch managedocs managedocs -n openshift-storage -p '{"metadata":{"finalizers":null}}' --type=merge

echo -e "\n${Cyan}Deleting managedocs CR${EndColor}"
kubectl delete managedocs managedocs -n openshift-storage --cascade='orphan'

echo -e "\n${Cyan}Deleting addon deletion configmap${EndColor}"
kubectl delete configmap ocs-consumer$2 -n openshift-storage

# echo -e "\nDeleting addon catalog source"
# kubectl delete catsrc addon-ocs-consumer-catalog -n openshift-storage

echo -e "\n${Cyan}Scaling up the addon-operator-manager${EndColor}"
kubectl scale deployment addon-operator-manager -n openshift-addon-operator --replicas 1
echo -e "${Green}Deatach addon script completed!${EndColor}\n"
