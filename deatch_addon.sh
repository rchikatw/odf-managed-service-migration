#!/bin/bash

usage() {
  cat << EOF

  Deatch the ODF MS consumer addon from hive

  Requirements:
    1. A ROSA cluster with ODF MS Consumer addon installed.
    2. kubectl, rosa, ocm and jq installed.

  USAGE: "./deatachaddon.sh <kubeconfig> <clusterID>"

  Please note that we need to provide the absolute path to kubeconfig and clusterID or name

  To install jq or yq Refer:
  1. jq: https://www.cyberithub.com/how-to-install-jq-json-processor-on-rhel-centos-7-8/

EOF
}

validate() {

  if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
    usage
    exit 0
  fi

  if hash rosa 2>/dev/null; then
    echo "OK, you have rosa installed. We will use that."
  else
    echo "rosa is not installed, Please install and rerun the restore script"
    usage
    exit
  fi

  if hash ocm 2>/dev/null; then
    echo "OK, you have ocm installed. We will use that."
  else
    echo "ocm is not installed, Please install and rerun the restore script"
    usage
    exit
  fi

  if hash jq 2>/dev/null; then
    echo "OK, you have jq installed. We will use that."
  else
    echo "jq is not installed, Please install and rerun the restore script"
    usage
    exit
  fi

  if [[ -z "$1" ]]
  then
    echo "Missing kubeconfig!!"
    usage
    exit 1
  fi

  echo "kubeconfig path: "$1

  if [[ -z "$2" ]]
  then
    echo "Missing Cluster id!!"
    usage
    exit 1
  fi

}

validate "$1" "$2"

export KUBECONFIG=$1

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
rosa uninstall addons -c $2 ocs-consumer -y

while true
do

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$2/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer") | .state')

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

  state=$(ocm get /api/clusters_mgmt/v1/clusters/$2/addons | jq  -r '. | select(.items != null) | .items[] | select(.id == "ocs-consumer") | .state')

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
