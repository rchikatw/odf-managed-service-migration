#!/bin/bash
echo -e "\nCreating required directories for backup"
mkdir backup
cd backup
mkdir {deployments,persistentvolumes,persistentvolumeclaims,secrets,storageconsumers}

echo -e "\nBacking up Deployments"
cd deployments
oc get deployment -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-osd' | awk 'NR!=1 {print}' | awk '{ cmd="oc get deployment "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "\nBacking up PV"
cd ../persistentvolumes
oc get persistentvolume | grep openshift-storage  | awk '{ cmd="oc get persistentvolume "$1" -o json > " $1".json"; system(cmd) }'

echo -e "\nBacking up PVC"
cd ../persistentvolumeclaims
oc get persistentvolumeclaim -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="oc get persistentvolumeclaim "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "\nBacking up secrets"
cd ../secrets
oc get secret -n openshift-storage | grep 'rook-ceph-mon\|rook-ceph-mons-keyring\|rook-ceph-admin-keyring' | awk '{ cmd="oc get secret "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'

echo -e "\nBacking up consumers"
cd ../storageconsumers
oc get storageconsumers -n openshift-storage | awk 'NR!=1 {print}' | awk '{ cmd="oc get storageconsumers "$1" -n openshift-storage -o json > " $1".json"; system(cmd) }'






