#!/bin/bash

usage() {
  cat << EOF
 
  Update the StorageConsumer id in the status section of StorageCluster CR.
 
  Requirements:
    1. A ROSA cluster with ODF MS Consumer addon installed.
    2. kubectl & curl installed.
 
  USAGE: "./restoreConsumer.sh <kubeconfig> <storageConsumerUid>"

 
EOF
}

validate() {

  if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
    usage
    exit 0
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
    echo "Missing Storage Cluster uid!!"
    usage
    exit 1
  fi

  echo "Storage Cluster uid: "$2

}

validate "$1" "$2"
export KUBECONFIG=$1

kill $(lsof -t -i:8081)
kubectl proxy --port=8081 &

sleep 2

DATA="{\"status\":{\"externalStorage\":{\"id\":\"$2\"}}}"
ENDPOINT="localhost:8081/apis/ocs.openshift.io/v1/namespaces/openshift-storage/storageclusters/ocs-storagecluster/status"
curl -X PATCH -H 'Content-Type: application/merge-patch+json' --data ${DATA} ${ENDPOINT}

kill $(lsof -t -i:8081)

echo "Restore consumer script complted, Please edit the Stroage provider endpoint from UI. "