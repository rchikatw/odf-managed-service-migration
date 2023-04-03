#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Update the StorageConsumer id and StorageProviderEndpoint in the StorageCluster CR.

  Requirements:
    1. A ROSA cluster with ODF in external mode.
    2. kubectl & curl installed.

  USAGE: "./restoreConsumer.sh <storageProviderEndpoint> <StorageConsumerUID>"

  To install kubectl,  ocm & jq refer:
  1. kubectl: ${link[kubectl]}
  2. curl: ${link[curl]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

kubectl patch storagecluster ocs-storagecluster -n openshift-storage -p '{"spec": {"externalStorage": {"storageProviderEndpoint": "'${1}'"}}}' --type merge

# kubectl patch storagecluster ocs-storagecluter --subresource=status --type='merge' -p '{"status":{"externalStorage":{“id”:”<new-id>”}}}'

kill $(lsof -t -i:8081)
kubectl proxy --port=8081 &

sleep 2

DATA="{\"status\":{\"externalStorage\":{\"id\":\"$2\"}}}"
ENDPOINT="localhost:8081/apis/ocs.openshift.io/v1/namespaces/openshift-storage/storageclusters/ocs-storagecluster/status"
curl -X PATCH -H 'Content-Type: application/merge-patch+json' --data ${DATA} ${ENDPOINT}

kill $(lsof -t -i:8081)

kubectl rollout restart deployment ocs-operator -n openshift-storage

echo -e "${Green}\nRestore consumer script complted!"
