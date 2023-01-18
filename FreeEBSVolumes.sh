#!/bin/bash

usage() {
  cat << EOF

  Remove the osd and mon pods on the provider cluster.

  Requirements:
    1. kubectl installed.
    2. kubeconfig for the cluster

  USAGE: "./remove-rook-osd-mon-pods.sh <kubeconfig>"

EOF
}

# Set the kubeconfig file.
kubeconfig_file="$1"

# Check if the kubeconfig file exists.
if [[ ! -f "$kubeconfig_file" ]]
then
  echo "kubeconfig file not found: $kubeconfig_file"
  exit 1
fi

# Set the kubeconfig file in the KUBECONFIG environment variable.
export KUBECONFIG="$kubeconfig_file"

# Switch to the openshift-storage namespace.
echo "Switching to the openshift-storage namespace"
kubectl config set-context --current --namespace=openshift-storage

# Scale the rook-ceph-operator deployment to 0 replicas.
kubectl scale deployment rook-ceph-operator --replicas 0

# Scale all deployments with the "rook-ceph-mon" label to 0 replicas.
kubectl scale deployment --replicas 0 --selector=app=rook-ceph-mon

# Scale all deployments with the "rook-ceph-osd" label to 0 replicas.
kubectl scale deployment --replicas 0 --selector=app=rook-ceph-osd