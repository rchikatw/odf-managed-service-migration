#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Migrate a ODFMS consumer into the new ocs-client operator.

  Requirements:
    1. All the pods/deployments using PVC should be scaled down.
    2. Consumer Addon is deatached
    3. OCP version of the cluster should be >= 4.11

  USAGE: "./migrateConsumer.sh <Consumer Cluster ID>"

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

backupVolumes() {
  data=$(kubectl get pv | grep ${1} | awk '{print $6}')
  namespace="${data%%/*}"
  name="${data#*/}"
  kubectl get pv ${1} -oyaml > $backupDirectoryName/pv/$2/$1.yaml
  kubectl get pvc ${name} -n ${namespace} -oyaml > $backupDirectoryName/pvc/$2/$name.yaml
}

backupConsumerResources() {
  #pvc and pv backup
  for pvName in "${rbdPVNames[@]}"
  do
    # echo $pvName
    backupVolumes "$pvName" "rbd" &
  done

  for pvName in "${fsPVNames[@]}"
  do
    # echo $pvName
    backupVolumes "$pvName" "cephfs" &
  done

  sleep 2

  #storageCluster backup
  kubectl get storagecluster -n openshift-storage -oyaml > $backupDirectoryName/storagecluster.yaml

  #storageClassClaim backup
  kubectl get storageclassclaim -n openshift-storage -oyaml > $backupDirectoryName/storageclassclaim.yaml
}

releasePV() {
  #edit pv to change reclaim policy to retain, and delete the pvc to release PV
  pvFilenames=("${rbdPVNames[@]}" "${fsPVNames[@]}")
  for pvName in "${pvFilenames[@]}";
  do
    kubectl patch pv ${pvName} --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

    data=$(kubectl get pv ${pvName} --no-headers | awk '{print $6}')
    namespace="${data%%/*}"
    name="${data#*/}"
    kubectl delete pvc $name -n ${namespace}
  done

  for pvName in "${pvFilenames[@]}";
  do
    while true
    do
      pvStatus=$(kubectl get pv ${pvName} --no-headers | awk '{print $5;exit}')
      if [[ $pvStatus == *"Released"* ]]
      then
          kubectl delete pv ${pvName}
          break
      fi
      echo "${Blue}waiting for PV "$pvName" to go to released state, current state is ${EndColor}"$pvStatus
      sleep 5
    done
  done
}

deleteNamespace(){

  kubectl get csv -n openshift-storage | grep 'ocs\|odf\|mcg\|ose' | awk '{print $1}' | xargs kubectl delete csv -n openshift-storage
  kubectl get subs -n openshift-storage | grep 'ocs\|odf\|mcg' | awk '{print $1}' | xargs kubectl delete subs -n openshift-storage

  resources=("cephcluster" "storagecluster" "storagesystem" "cephfilesystemsubvolumegroup" "storageclassclaim" "csiaddonsnode")
  for resource in "${resources[@]}"
  do
    kubectl get $resource -n openshift-storage --no-headers=true | awk '{print $1}'| xargs kubectl patch $resource -n openshift-storage -p '{"metadata":{"finalizers":null}}' --type=merge
  done

  kubectl patch cm rook-ceph-mon-endpoints -n openshift-storage  -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage

  kubectl get csidriver | grep 'openshift-storage' | awk '{print $1}' | xargs kubectl delete csidriver

  kubectl delete project openshift-storage

  kubectl get crd | grep 'ocs\|nooba\|odf\|ceph\|csi' | awk '{print $1}' | xargs kubectl delete crd

}

createOCSClientOperator() {
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ocs-client-catalogsource
  namespace: openshift-marketplace
spec:
  grpcPodConfig:
    securityContextConfig: legacy
  sourceType: grpc
  image: quay.io/madhupr001/ocs-client-operator-catalog:latest
  displayName: OpenShift Data Foundation Client Operator
  publisher: Red Hat
---
apiVersion: v1
kind: Namespace
metadata:
  name: ocs-client-ns
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ocs-client-operatorgroup
  namespace: ocs-client-ns
spec:
  targetNamespaces:
    - ocs-client-ns
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ocs-client-operator
  namespace: ocs-client-ns
spec:
  channel: alpha
  installPlanApproval: Automatic
  name: ocs-client-operator
  source: ocs-client-catalogsource
  sourceNamespace: openshift-marketplace
EOF
}
checkOperatorCSV() {
  
  while true
  do
    csvStatus=$(kubectl get csv -n ${operatorNamespace} | grep ocs-client-operator | awk '{ print $7; exit }')
    echo -e "\n${Blue}Waiting for ocs-client-operator CSV to come to Succeeded phase, current CSV Status is ${EndColor}"$csvStatus
    
    if [[ $csvStatus == *"Succeeded"* ]]
    then
      break
    fi
    sleep 30
  done
}

createStorageClient() {
  id=$2
  onBoardingTicket=$(yq '.items[].spec.externalStorage.onboardingTicket' $backupDirectoryName/storagecluster.yaml)
  storageProviderEndpoint=$1

  yq eval -i '.metadata .name="'${storageClientName}'" | .metadata .namespace="'${operatorNamespace}'" | .spec .onboardingTicket="'${onBoardingTicket}'" | .spec .storageProviderEndpoint = "'${storageProviderEndpoint}'" ' storageClient.yaml
  kubectl apply -f storageClient.yaml
  kubectl patch --subresource=status storageclient ${storageClientName} -n ${operatorNamespace} --type=merge --patch '{"status":{"id":"'${id}'", "phase": "Onboarding"}}'
}

checkStorageClient() {
  while true
  do
    clientStatus=$(kubectl get storageclient ${storageClientName} -n ${operatorNamespace} --no-headers | awk '{ print $2; exit }')
    echo "${Blue}Waiting for storageclient to come in Connected phase, current Stauts is ${EndColor}"$clientStatus
    if [[ $clientStatus == *"Connected"* ]]
    then
      break
    fi
    sleep 15
  done
}

applyStorageClassClaim() {
  yq eval -i '.items[].spec +={"storageClient":{"name":"'${storageClientName}'","namespace":"'${operatorNamespace}'"}}' $backupDirectoryName/storageclassclaim.yaml
  kubectl apply -f $backupDirectoryName/storageclassclaim.yaml
}

checkStorageClassClaim() {
  while true
  do
    claimStatusOne=$(kubectl get storageclassclaim -n ${operatorNamespace} --no-headers | awk '{print $5}' | awk 'FNR == 1')
    claimNameOne=$(kubectl get storageclassclaim -n ${operatorNamespace} --no-headers | awk '{print $1}' | awk 'FNR == 1')

    claimStatusTwo=$(kubectl get storageclassclaim -n ${operatorNamespace} --no-headers | awk '{print $5}' | awk 'FNR == 2')
    claimNameTwo=$(kubectl get storageclassclaim -n ${operatorNamespace} --no-headers | awk '{print $1}' | awk 'FNR == 2')

    echo "${Blue}Waiting for storageClassClaim ${EndColor}"${claimNameOne}" ${Blue}to come to Ready phase, current phase is ${EndColor}"$claimStatusOne
    echo "${Blue}Waiting for storageClassClaim ${EndColor}"${claimNameTwo}" ${Blue}to come to Ready phase, current phase is ${EndColor}"$claimStatusTwo
    if [[ $claimStatusOne == *"Ready"* && $claimStatusTwo == *"Ready"* ]]
    then
      break
    fi
    sleep 5
  done
}

patchRBDPV() {
  kubectl get sc ocs-storagecluster-ceph-rbd -oyaml > $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml

  annotationProvisionedBy="${operatorNamespace}.rbd.csi.ceph.com"
  controllerExpandSecretRefNamespace=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-namespace"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  controllerExpandSecretRefName=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-name"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  csiDriver="${operatorNamespace}.rbd.csi.ceph.com"
  nodeStageSecretNamespace=$(yq '.parameters ."csi.storage.k8s.io/node-stage-secret-namespace"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  nodeStageSecretName=$(yq '.parameters ."csi.storage.k8s.io/node-stage-secret-name"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  provisionerSecretNamespace=$(yq '.parameters ."csi.storage.k8s.io/provisioner-secret-namespace"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  provisionerSecretName=$(yq '.parameters ."csi.storage.k8s.io/provisioner-secret-name"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  clusterID=$(yq '.parameters .clusterID' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)

  pvFilenames=`ls  $backupDirectoryName/pv/rbd/`
  for pv in $pvFilenames; do
    volumeHandle=$(yq '.spec .csi .volumeHandle' $backupDirectoryName/pv/rbd/$pv)
    newVolumeHandle=${volumeHandle/1-openshift-storage/b-ocs-storagecluster-ceph-rbd}

    #patch
    yq eval -i '.metadata .annotations ."pv.kubernetes.io/provisioned-by"="'$annotationProvisionedBy'" |
    .metadata .annotations ."volume.kubernetes.io/provisioner-deletion-secret-name"="'$provisionerSecretName'" |
    .metadata .annotations ."volume.kubernetes.io/provisioner-deletion-secret-namespace"="'$provisionerSecretNamespace'" |
    .spec .csi .controllerExpandSecretRef .name="'$controllerExpandSecretRefName'" |
    .spec .csi .controllerExpandSecretRef .namespace="'$controllerExpandSecretRefNamespace'" |
    .spec .csi .nodeStageSecretRef .name="'$nodeStageSecretName'" |
    .spec .csi .nodeStageSecretRef .namespace="'$nodeStageSecretNamespace'" |
    .spec .csi .driver="'$csiDriver'" |
    .spec .csi .volumeAttributes .clusterID="'$clusterID'" |
    .spec .csi .volumeHandle="'$newVolumeHandle'"
    ' $backupDirectoryName/pv/rbd/$pv

    yq eval -i 'del(.spec .claimRef) | del(.spec .csi .volumeAttributes ."storage.kubernetes.io/csiProvisionerIdentity")' $backupDirectoryName/pv/rbd/$pv

    kubectl apply -f $backupDirectoryName/pv/rbd/$pv

  done
}

patchFSPV() {
  kubectl get sc ocs-storagecluster-cephfs -oyaml > $backupDirectoryName/ocs-storagecluster-cephfs.yaml

  annotationProvisionedBy="${operatorNamespace}.cephfs.csi.ceph.com"
  controllerExpandSecretRefNamespace=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-namespace"' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)
  controllerExpandSecretRefName=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-name"' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)
  csiDriver="${operatorNamespace}.cephfs.csi.ceph.com"
  nodeStageSecretNamespace=$(yq '.parameters ."csi.storage.k8s.io/node-stage-secret-namespace"' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)
  nodeStageSecretName=$(yq '.parameters ."csi.storage.k8s.io/node-stage-secret-name"' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)
  clusterID=$(yq '.parameters .clusterID' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)

  pvFilenames=`ls  $backupDirectoryName/pv/cephfs/`
  for pv in $pvFilenames; do
    oldClusterID=$(yq '.spec .csi .volumeAttributes .clusterID' $backupDirectoryName/pv/cephfs/$pv)
    old="20-"${oldClusterID}
    volumeHandle=$(yq '.spec .csi .volumeHandle' $backupDirectoryName/pv/cephfs/$pv)
    newVolumeHandle=${volumeHandle/$old/19-ocs-storagecluster-cephfs}

    #patch
    yq eval -i '.metadata .annotations ."pv.kubernetes.io/provisioned-by"="'$annotationProvisionedBy'" |
    .spec .csi .controllerExpandSecretRef .name="'$controllerExpandSecretRefName'" |
    .spec .csi .controllerExpandSecretRef .namespace="'$controllerExpandSecretRefNamespace'" |
    .spec .csi .nodeStageSecretRef .name="'$nodeStageSecretName'" |
    .spec .csi .nodeStageSecretRef .namespace="'$nodeStageSecretNamespace'" |
    .spec .csi .driver="'$csiDriver'" |
    .spec .csi .volumeAttributes .clusterID="'$clusterID'" |
    .spec .csi .volumeHandle="'$newVolumeHandle'"
    ' $backupDirectoryName/pv/cephfs/$pv

    yq eval -i 'del(.spec .claimRef) | del(.spec .csi .volumeAttributes ."storage.kubernetes.io/csiProvisionerIdentity")' $backupDirectoryName/pv/cephfs/$pv

    kubectl apply -f $backupDirectoryName/pv/cephfs/$pv

  done
}

patchRBDPVC() {
  pvcFilenames=`ls  $backupDirectoryName/pvc/rbd/`
  for pvc in $pvcFilenames; do
    sed -i 's/openshift-storage/'${operatorNamespace}'/g' $backupDirectoryName/pvc/rbd/$pvc
    kubectl apply -f $backupDirectoryName/pvc/rbd/$pvc
  done
}

patchFSPVC() {
  pvcFilenames=`ls  $backupDirectoryName/pvc/cephfs/`
  for pvc in $pvcFilenames; do
    sed -i 's/openshift-storage/'${operatorNamespace}'/g' $backupDirectoryName/pvc/cephfs/$pvc
    kubectl apply -f $backupDirectoryName/pvc/cephfs/$pvc
  done
}

operatorNamespace="ocs-client-ns"
storageClientName="storageclient"

backupDirectoryName=backup_consumer/${3}

mkdir -p ${backupDirectoryName}
mkdir -p ${backupDirectoryName}/pv/rbd
mkdir -p ${backupDirectoryName}/pv/cephfs
mkdir -p ${backupDirectoryName}/pvc/rbd
mkdir -p ${backupDirectoryName}/pvc/cephfs

rbdPVNames=( $(kubectl get pv | grep ocs-storagecluster-ceph-rbd | awk '{print $1}') )
fsPVNames=( $(kubectl get pv | grep ocs-storagecluster-cephfs | awk '{print $1}') )

echo "${Green}Migrate consumer script started${EndColor}"
backupConsumerResources

releasePV

deleteNamespace

createOCSClientOperator

checkOperatorCSV

#scale down the operator
kubectl scale deployments ocs-client-operator-controller-manager -n $operatorNamespace --replicas 0

createStorageClient $1 $2

#scale up the operator
kubectl scale deployments ocs-client-operator-controller-manager -n $operatorNamespace --replicas 1

checkStorageClient

applyStorageClassClaim

checkStorageClassClaim

patchRBDPV

patchFSPV

patchRBDPVC

patchFSPVC

echo "${Green}Migrate consumer script completed!${EndColor}"
