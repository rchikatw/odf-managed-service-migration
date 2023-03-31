#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Takes the backup of required resources for restoring/migrating provider cluster.

  Requirements:
    1. kubectl, ocm installed.
    2. clusterID for the cluster

  USAGE: "./backupResources.sh <incluster|s3>"

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

case "$1" in
  incluster)
    cd backup/

    echo -e "Backing up Deployments"
    cd deployments
    kubectl get deployment -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-osd' | awk '{ cmd="kubectl get deployment "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

    echo -e "Backing up PV"
    cd ../persistentvolumes
    kubectl get persistentvolume | grep openshift-storage  | awk '{ cmd="kubectl get persistentvolume "$1" -o json > " $1".json"; system(cmd) }'

    echo -e "Backing up PVC"
    cd ../persistentvolumeclaims
    kubectl get persistentvolumeclaim -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="kubectl get persistentvolumeclaim "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

    echo -e "Backing up secrets"
    cd ../secrets
    kubectl get secret -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-mons-keyring\|rook-ceph-admin-keyring' | awk '{ cmd="kubectl get secret "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

    echo -e "Backing up storageConsumers"
    cd ../storageconsumers
    kubectl get storageconsumers -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="kubectl get storageconsumers "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

    echo -e "Backing up storageClassClaim"
    cd ../storageclassclaims
    kubectl get storageclassclaim -n openshift-storage -ojson > storageclassclaims.json

    echo -e "Backing up cephClient"
    cd ../cephclients
    kubectl get cephclient -n openshift-storage -ojson > cephclients.json
    ;;
  s3)
    echo "Enter s3 URL"
    read s3URL

    rm -rf s3backup
    mkdir -p s3backup
    cd s3backup

    echo "Downloading backup"
    curl -o s3backup.tar $s3URL

    echo "Extracting backup"
    tar -xf s3backup.tar
    cd ..

    #TODO: backup cephclient
    echo "Formatting s3 backup"
    cp s3backup/resources/deployments.apps/namespaces/openshift-storage/rook-ceph-mon-* s3backup/resources/deployments.apps/namespaces/openshift-storage/rook-ceph-osd-* backup/deployments

    cp s3backup/resources/persistentvolumes/cluster/* backup/persistentvolumes

    cp s3backup/resources/persistentvolumeclaims/namespaces/openshift-storage/* backup/persistentvolumeclaims

    cp s3backup/resources/secrets/namespaces/openshift-storage/rook-ceph-mon* s3backup/resources/secrets/namespaces/openshift-storage/rook-ceph-admin-keyring* backup/secrets

    cp s3backup/resources/storageconsumers.ocs.openshift.io/namespaces/openshift-storage/* backup/storageconsumers

    cp s3backup/resources/storageclassclaims.ocs.openshift.io/namespaces/openshift-storage/* backup/storageclassclaims

    cp s3backup/resources/cephclients.ceph.rook.io/namespaces/openshift-storage/* backup/cephclients
    ;;
  *)
    echo "Invalid Option, exiting..."
    exit
esac
