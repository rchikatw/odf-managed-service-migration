#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Scale down the osd and mon pods on the provider cluster.

  Requirements:
    1. kubectl installed.

  USAGE: "./freeEBSVolumes.sh"

  To install kubectl refer:
  1. kubectl: ${link[kubectl]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

# Switch to the openshift-storage namespace.
echo "Switching to the openshift-storage namespace"
kubectl config set-context --current --namespace=openshift-storage

# Scale the rook-ceph-operator deployment to 0 replicas.
kubectl scale deployment rook-ceph-operator --replicas 0

# Scale all deployments with the "rook-ceph-mon" label to 0 replicas.
kubectl scale deployment --replicas 0 --selector=app=rook-ceph-mon

# Scale all deployments with the "rook-ceph-osd" label to 0 replicas.
kubectl scale deployment --replicas 0 --selector=app=rook-ceph-osd
