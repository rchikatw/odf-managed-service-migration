#!/bin/bash

usage() {
  cat << EOF

  Update the StorageConsumer id and StorageProviderEndpoint in the StorageCluster CR.

  Requirements:
    1. A ROSA cluster with ODF MS Consumer addon installed.
    2. kubectl & curl installed.

  USAGE: "./restore_consumer.sh <kubeconfig> <storageConsumerUid> <storageProviderEndpoint>"


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
    echo "Missing Storage Consumer uid!!"
    usage
    exit 1
  fi

  echo "Storage Consumer uid: "$2

  if [[ -z "$3" ]]
  then
    echo "Missing Storage Provider endpoint!!"
    usage
    exit 1
  fi

  echo "Storage Provider endpoint: "$3

}

validate "$1" "$2" "$3"
export KUBECONFIG=$1

kubectl patch storagecluster ocs-storagecluster -n openshift-storage -p '{"spec": {"externalStorage": {"storageProviderEndpoint": "'${3}'"}}}' --type merge

kill $(lsof -t -i:8081)
kubectl proxy --port=8081 &

sleep 2

DATA="{\"status\":{\"externalStorage\":{\"id\":\"$2\"}}}"
ENDPOINT="localhost:8081/apis/ocs.openshift.io/v1/namespaces/openshift-storage/storageclusters/ocs-storagecluster/status"
curl -X PATCH -H 'Content-Type: application/merge-patch+json' --data ${DATA} ${ENDPOINT}

kill $(lsof -t -i:8081)

kubectl rollout restart deployment ocs-operator -n openshift-storage

echo "Restore consumer script complted!"
