#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Scale down the osd and mon pods on the provider cluster.

  Requirements:
    1. ClusterId.
    2. kubectl: ${link[kubectl]}

  USAGE: "./freeEBSVolumes.sh <oldClusterID> -d"

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

loginCluster $1 $2 $3

echo -e "${Green}Detaching the EBS volume from old cluster${EndColor}"

echo -e "\n${Cyan}Scaling down the pods connected to the EBS Volumes${EndColor}"
# Scale the rook-ceph-operator, ocs-operator and ocs-provider-server deployment to 0 replicas.
kubectl scale deployment rook-ceph-operator -n openshift-storage --replicas 0
kubectl scale deployment ocs-provider-server -n openshift-storage --replicas 0
kubectl scale deployment ocs-operator -n openshift-storage --replicas 0

# Scale all deployments with the "rook-ceph-mon" label to 0 replicas.
kubectl scale deployment --replicas 0 -n openshift-storage --selector=app=rook-ceph-mon

# Scale all deployments with the "rook-ceph-osd" label to 0 replicas.
kubectl scale deployment --replicas 0 -n openshift-storage --selector=app=rook-ceph-osd
echo -e "${Cyan}Scaling down Complete!${EndColor}"
echo -e "${Green}Finished detaching the EBS volume from old cluster!${EndColor}\n"
