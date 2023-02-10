#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Deatch the ODF MS consumer addon from hive

  Requirements:
    1. A ROSA cluster with ODF MS Consumer addon installed.
    2. kubectl, rosa, ocm and jq installed.

  USAGE: "./deatach_addon.sh"

  To install kubectl, rosa, ocm & jq refer:
  1. kubectl: ${link[kubectl]}
  2. jq: ${link[jq]}
  3. rosa: ${link[rosa]}
  4. ocm: ${link[ocm]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

validate "kubectl" "ocm" "rosa" "jq"

echo "Enter the clusterID for consumer:"
read clusterID

storeKubeconfigAndLoginCluster "$clusterID"

echo -e "\nScaling down the addon-operator-manager"
kubectl scale deployment addon-operator-manager -n openshift-addon-operator --replicas 0

# removing owner ref from namespace and subscription
echo -e "\nDeleting addoninstance from openshift-storage namespace"
kubectl delete addoninstance addon-instance -n openshift-storage --cascade='orphan'

echo "Patching the addon ocs-consumer to remove finalizers"
kubectl patch addon ocs-consumer -p '{"metadata":{"finalizers":null}}' --type=merge

echo -e "\nDeleting addon ocs-consumer"
kubectl delete addon ocs-consumer --cascade='orphan'

echo -e "\nScaling down the ocs-osd-deployer"
kubectl scale deployment ocs-osd-controller-manager -n openshift-storage --replicas=0

echo -e "\nUninstalling consumer addon"
#TODO: unintall from UI or from ROSA command
rosa uninstall addons -c $clusterID ocs-consumer -y

while true
do

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$clusterID/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer") | .state')

  echo "waiting for addon to be uninstalled current state is "$state
  if [[ $state == "deleting" ]];
  then
      break
  fi
  sleep 60
done

echo -e "\nDeleting ocs-osd-deployer-csv"
kubectl delete csv $(kubectl get csv -n openshift-storage | grep ocs-osd | awk '{print $1}') -n openshift-storage

# we can also try to rosa list adons and then check the status here
while true
do

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$clusterID/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer") | .state')

  echo "waiting for addon to be uninstalled current state is "$state
  if [ -z "$state" ];
  then
      break
  fi
  sleep 60
done

echo -e "\nUninstalled ocs-consumer addon"

echo -e "\nDeleting addon/ocs-osd-deployer subscription"
kubectl delete subs addon-ocs-consumer -n openshift-storage

echo "Patching the managedocs to remove finalizers"
kubectl patch managedocs managedocs -n openshift-storage -p '{"metadata":{"finalizers":null}}' --type=merge
echo -e "\nDeleting managedocs CR"
kubectl delete managedocs managedocs -n openshift-storage --cascade='orphan'

echo -e "\nDeleting addon deletion configmap"
kubectl delete configmap ocs-consumer -n openshift-storage

# echo -e "\nDeleting addon catalog source"
# kubectl delete catsrc addon-ocs-consumer-catalog -n openshift-storage

echo -e "\nScaling up the addon-operator-manager"
kubectl scale deployment addon-operator-manager -n openshift-addon-operator --replicas 1
