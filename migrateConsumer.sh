#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Migrate a ODFMS consumer into the new ocs-client operator.

  Requirements:
    1. All the pods/deployments using PVC should be scaled down.
    2. Consumer Addon is deatached
    3. OCP version of the cluster should be >= 4.11

  USAGE: "./migrateConsumer.sh <storageProviderEndpoint> <storageConsumerUID> <consumerClusterID> [-d]"

  Note:
  1. Use -d when not using ocm-backplane
  2. StorageProviderEndpoint of the new Provider
  3. StorageConsumerUID from the new Provider
  4. OCM consumerClusterID

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 1
fi

backupVolumes() {
  data=$(kubectl get pv | grep ${1} | awk '{print $6}')
  namespace="${data%%/*}"
  name="${data#*/}"
  kubectl get pv ${1} -oyaml > $backupDirectoryName/pv/$2/$1.yaml
  kubectl get pvc ${name} -n ${namespace} -oyaml > $backupDirectoryName/pvc/$2/$name.yaml
}

backupConsumerResources() {

  echo -e "\n${Cyan}Backing up PV, PVC, storageCluster and storageClassClaim${EndColor}"
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

  echo -e "\n${Cyan}Deleting the PVC followed by PV ${EndColor}"
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
      echo -e "${Blue}waiting for PV "$pvName" to go to released state, current state is ${EndColor}"$pvStatus
      sleep 5
    done
  done
}

deleteNamespace(){

  echo -e "\n${Cyan}Deleting the namespace openshift-storage and everything in it ${EndColor}"

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
  image: quay.io/rhceph-dev/ocs-registry:4.13.0-168
  displayName: OpenShift Data Foundation Client Operator
  publisher: Red Hat
---
apiVersion: v1
kind: Namespace
metadata:
  name: fusion-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ocs-client-operatorgroup
  namespace: fusion-storage
spec:
  targetNamespaces:
    - fusion-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ocs-client-operator
  namespace: fusion-storage
spec:
  channel: stable-4.13
  installPlanApproval: Automatic
  name: ocs-client-operator
  source: ocs-client-catalogsource
  sourceNamespace: openshift-marketplace
EOF
}

checkOperatorCSV() {

  while true
  do
    csvStatus=$(kubectl get csv -n ${clientOperatorNamespace} $(kubectl get csv -n ${clientOperatorNamespace}| grep ocs-client-operator | awk '{print $1;exit}') -oyaml | yq '.status .phase')
    echo -e "${Blue}Waiting for ocs-client-operator CSV to come to Succeeded phase, current CSV Status is ${EndColor}"$csvStatus

    if [[ $csvStatus == *"Succeeded"* ]]
    then
      break
    fi
    sleep 30
  done
}

createStorageClient() {

  echo -e "\n${Cyan}Creating storageClient${EndColor}"
  id=$2
  onBoardingTicket=$(yq '.items[].spec.externalStorage.onboardingTicket' $backupDirectoryName/storagecluster.yaml)
  storageProviderEndpoint=$1
  
  cp storageClient.yaml storageClient${2}.yaml
  yq eval -i '.metadata .name="'${storageClientName}'" | .metadata .namespace="'${clientOperatorNamespace}'" | .spec .onboardingTicket="'${onBoardingTicket}'" | .spec .storageProviderEndpoint = "'${storageProviderEndpoint}'" ' storageClient${2}.yaml
  kubectl apply -f storageClient${2}.yaml
  rm storageClient${2}.yaml
  kubectl patch --subresource=status storageclient ${storageClientName} -n ${clientOperatorNamespace} --type=merge --patch '{"status":{"id":"'${id}'", "phase": "Onboarding"}}'
}

checkStorageClient() {
  while true
  do
    clientStatus=$(kubectl get storageclient ${storageClientName} -n ${clientOperatorNamespace} -oyaml | yq '.status .phase')
    echo -e "${Blue}Waiting for storageclient to come in Connected phase, current Stauts is ${EndColor}"$clientStatus
    if [[ $clientStatus == *"Connected"* ]]
    then
      break
    fi
    sleep 15
  done
}

applyStorageClassClaim() {
  echo -e "\n${Cyan}Applying storageClassClaim from backup${EndColor}"
  yq eval -i '.items[].spec +={"storageClient":{"name":"'${storageClientName}'","namespace":"'${clientOperatorNamespace}'"}}' $backupDirectoryName/storageclassclaim.yaml
  kubectl apply -f $backupDirectoryName/storageclassclaim.yaml
}

checkStorageClassClaim() {
  while true
  do
    claimNameOne=$(kubectl get storageclassclaim -n ${clientOperatorNamespace} --no-headers | awk '{print $1}' | awk 'FNR == 1')
    claimStatusOne=$(kubectl get storageclassclaim -n ${clientOperatorNamespace} ${claimNameOne} -oyaml | yq '.status .phase')

    claimNameTwo=$(kubectl get storageclassclaim -n ${clientOperatorNamespace} --no-headers | awk '{print $1}' | awk 'FNR == 2')
    claimStatusTwo=$(kubectl get storageclassclaim -n ${clientOperatorNamespace} ${claimNameTwo} -oyaml | yq '.status .phase')

    echo -e "${Blue}Waiting for storageClassClaim ${EndColor}"${claimNameOne}" ${Blue}to come to Ready phase, current phase is ${EndColor}"$claimStatusOne
    echo -e "${Blue}Waiting for storageClassClaim ${EndColor}"${claimNameTwo}" ${Blue}to come to Ready phase, current phase is ${EndColor}"$claimStatusTwo
    if [[ $claimStatusOne == *"Ready"* && $claimStatusTwo == *"Ready"* ]]
    then
      break
    fi
    sleep 5
  done
}

patchRBDPV() {
  kubectl get sc ocs-storagecluster-ceph-rbd -oyaml > $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml

  annotationProvisionedBy="${clientOperatorNamespace}.rbd.csi.ceph.com"
  controllerExpandSecretRefNamespace=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-namespace"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  controllerExpandSecretRefName=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-name"' $backupDirectoryName/ocs-storagecluster-ceph-rbd.yaml)
  csiDriver="${clientOperatorNamespace}.rbd.csi.ceph.com"
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

  annotationProvisionedBy="${clientOperatorNamespace}.cephfs.csi.ceph.com"
  controllerExpandSecretRefNamespace=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-namespace"' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)
  controllerExpandSecretRefName=$(yq '.parameters ."csi.storage.k8s.io/controller-expand-secret-name"' $backupDirectoryName/ocs-storagecluster-cephfs.yaml)
  csiDriver="${clientOperatorNamespace}.cephfs.csi.ceph.com"
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
    sed -i 's/openshift-storage/'${clientOperatorNamespace}'/g' $backupDirectoryName/pvc/rbd/$pvc
    kubectl apply -f $backupDirectoryName/pvc/rbd/$pvc
  done
}

patchFSPVC() {
  pvcFilenames=`ls  $backupDirectoryName/pvc/cephfs/`
  for pvc in $pvcFilenames; do
    sed -i 's/openshift-storage/'${clientOperatorNamespace}'/g' $backupDirectoryName/pvc/cephfs/$pvc
    kubectl apply -f $backupDirectoryName/pvc/cephfs/$pvc
  done
}

if [ -z "${1}" ] || [ -z "${2}" ] || [ -z "${3}" ]; then
  usage
  exit 1
fi

loginCluster $3 $4

backupDirectoryName=backup_consumer/${3}

mkdir -p ${backupDirectoryName}
mkdir -p ${backupDirectoryName}/pv/rbd
mkdir -p ${backupDirectoryName}/pv/cephfs
mkdir -p ${backupDirectoryName}/pvc/rbd
mkdir -p ${backupDirectoryName}/pvc/cephfs

rbdPVNames=( $(kubectl get pv | grep ocs-storagecluster-ceph-rbd | awk '{print $1}') )
fsPVNames=( $(kubectl get pv | grep ocs-storagecluster-cephfs | awk '{print $1}') )

echo -e "${Green}Migrate consumer script started${EndColor}"
backupConsumerResources

releasePV

deleteNamespace

createOCSClientOperator

checkOperatorCSV

#scale down the operator
kubectl scale deployments $(kubectl get deployments -n $clientOperatorNamespace | grep ocs-client-operator | awk '{print $1;exit}') -n $clientOperatorNamespace --replicas 0

createStorageClient $1 $2

#scale up the operator
kubectl scale deployments $(kubectl get deployments -n $clientOperatorNamespace | grep ocs-client-operator | awk '{print $1;exit}') -n $clientOperatorNamespace --replicas 1

checkStorageClient

applyStorageClassClaim

checkStorageClassClaim

echo -e "\n${Cyan}Patching the PV and PVC before applying${EndColor}"

patchRBDPV

patchFSPV

patchRBDPVC

patchFSPVC

echo -e "${Green}Migrate consumer script completed!${EndColor}\n"
