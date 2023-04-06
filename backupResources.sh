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

echo -e "${Green}Backup of provider resource script started${EndColor}"
echo -e "${Cyan}Creating required directories for backup${EndColor}"

rm -rf backup
mkdir -p {backup/deployments,backup/persistentvolumes,backup/persistentvolumeclaims,backup/secrets,backup/storageconsumers,backup/storageclassclaims,backup/cephclients}

cd backup/

echo -e "${Cyan}Backing up Deployments${EndColor}"
cd deployments
kubectl get deployment -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-osd' | awk '{ cmd="kubectl get deployment "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "${Cyan}Backing up PV${EndColor}"
cd ../persistentvolumes
kubectl get persistentvolume | grep openshift-storage  | awk '{ cmd="kubectl get persistentvolume "$1" -o json > " $1".json"; system(cmd) }'

echo -e "${Cyan}Backing up PVC${EndColor}"
cd ../persistentvolumeclaims
kubectl get persistentvolumeclaim -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="kubectl get persistentvolumeclaim "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "${Cyan}Backing up secrets${EndColor}"
cd ../secrets
kubectl get secret -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-mons-keyring\|rook-ceph-admin-keyring' | awk '{ cmd="kubectl get secret "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "${Cyan}Backing up storageConsumers${EndColor}"
cd ../storageconsumers
kubectl get storageconsumers -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="kubectl get storageconsumers "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "${Cyan}Backing up storageClassClaim${EndColor}"
cd ../storageclassclaims
kubectl get storageclassclaim -n openshift-storage -ojson > storageclassclaims.json

echo -e "${Cyan}Backing up cephClient${EndColor}"
cd ../cephclients
kubectl get cephclient -n openshift-storage -ojson > cephclients.json

echo -e "${Green}Backup Provider resource script completed!${EndColor}\n"
