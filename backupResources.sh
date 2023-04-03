#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Takes the backup of required resources for restoring/migrating provider cluster.

  Requirements:
    1. kubectl, ocm installed.
    2. clusterID for the cluster

  USAGE: "./backupResources.sh"

  To install kubectl & ocm refer:
  1. kubectl: ${link[kubectl]}
  2. ocm: ${link[ocm]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

echo -e "Creating required directories for backup"
rm -rf backup
mkdir backup
cd backup
mkdir -p {deployments,persistentvolumes,persistentvolumeclaims,secrets,storageconsumers,storageclassclaims,cephclients}
cd ..

cd backup/

echo -e "{Cyan}Backing up Deployments"
cd deployments
kubectl get deployment -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-osd' | awk '{ cmd="kubectl get deployment "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "{Cyan}Backing up PV"
cd ../persistentvolumes
kubectl get persistentvolume | grep openshift-storage  | awk '{ cmd="kubectl get persistentvolume "$1" -o json > " $1".json"; system(cmd) }'

echo -e "{Cyan}Backing up PVC"
cd ../persistentvolumeclaims
kubectl get persistentvolumeclaim -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="kubectl get persistentvolumeclaim "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "{Cyan}Backing up secrets"
cd ../secrets
kubectl get secret -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-mons-keyring\|rook-ceph-admin-keyring' | awk '{ cmd="kubectl get secret "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "{Cyan}Backing up storageConsumers"
cd ../storageconsumers
kubectl get storageconsumers -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="kubectl get storageconsumers "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "{Cyan}Backing up storageClassClaim"
cd ../storageclassclaims
kubectl get storageclassclaim -n openshift-storage -ojson > storageclassclaims.json

echo -e "{Cyan}Backing up cephClient"
cd ../cephclients
kubectl get cephclient -n openshift-storage -ojson > cephclients.json

echo -e "{Green}Backing up Resources completed"
