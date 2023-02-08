#!/bin/bash

usage() {
  cat << EOF

  Takes the backup of required resources for restoring provider cluster.

  Requirements:
    1. kubectl installed.
    2. Cluster id of backup cluster

  USAGE: "./backup_resources.sh"

EOF
}

echo "Enter the cluster id"
read clusterId

storeKubeconfigAndLoginCluster() {
  ocm get /api/clusters_mgmt/v1/clusters/${clusterId}/credentials | jq -r .kubeconfig > ${clusterId}
  kubeconfigPath=$(readlink -f ${clusterId})
  export KUBECONFIG=$kubeconfigPath
}

storeKubeconfigAndLoginCluster

echo -e "Creating required directories for backup"
mkdir backup
cd backup
mkdir {deployments,persistentvolumes,persistentvolumeclaims,secrets,storageconsumers}

echo -e "Backing up Deployments"
cd deployments
oc get deployment -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-osd' | awk '{ cmd="oc get deployment "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "Backing up PV"
cd ../persistentvolumes
oc get persistentvolume | grep openshift-storage  | awk '{ cmd="oc get persistentvolume "$1" -o json > " $1".json"; system(cmd) }'

echo -e "Backing up PVC"
cd ../persistentvolumeclaims
oc get persistentvolumeclaim -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="oc get persistentvolumeclaim "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "Backing up secrets"
cd ../secrets
oc get secret -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-mons-keyring\|rook-ceph-admin-keyring' | awk '{ cmd="oc get secret "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "Backing up consumers"
cd ../storageconsumers
oc get storageconsumers -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="oc get storageconsumers "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'
