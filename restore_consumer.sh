#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Update the StorageConsumer id and StorageProviderEndpoint in the StorageCluster CR.

  Requirements:
    1. A ROSA cluster with ODF in external mode.
    2. kubectl & curl installed.

  USAGE: "./restore_consumer.sh"

  To install kubectl, rosa, ocm & jq refer:
  1. kubectl: ${link[kubectl]}
  2. curl: ${link[curl]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

validate "kubectl" "curl"

echo "Enter the clusterID for consumer:"
read clusterID

storeKubeconfigAndLoginCluster "$clusterID"

echo "Enter the Storage Consumer UID from the restore provider script:"
read storageConsumerUid

echo "Enter the Storage Provider endpoint from the restore provider script:"
read storageProviderEndpoint

kubectl patch storagecluster ocs-storagecluster -n openshift-storage -p '{"spec": {"externalStorage": {"storageProviderEndpoint": "'${storageProviderEndpoint}'"}}}' --type merge

kill $(lsof -t -i:8081)
kubectl proxy --port=8081 &

sleep 2

DATA="{\"status\":{\"externalStorage\":{\"id\":\"$storageConsumerUid\"}}}"
ENDPOINT="localhost:8081/apis/ocs.openshift.io/v1/namespaces/openshift-storage/storageclusters/ocs-storagecluster/status"
curl -X PATCH -H 'Content-Type: application/merge-patch+json' --data ${DATA} ${ENDPOINT}

kill $(lsof -t -i:8081)

kubectl rollout restart deployment ocs-operator -n openshift-storage

echo "Restore consumer script complted!"
