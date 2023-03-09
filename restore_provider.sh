#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Restore a ODF MS provider into a new cluster.

  Requirements:
    1. A new ROSA cluster with ODF MS Provider addon installed.
    2. Backup of resources from the old cluster.
    3. kubectl, yq and jq installed.

  USAGE: "./restore_provider.sh"

  Please note that we need to provide the absolute path to kubeconfig and s3 URL in ' '

  To install kubectl, jq or yq Refer:
    1. kubectl: ${link[kubectl]}
    2. yq: ${link[yq]}
    3. jq: ${link[jq]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

unset workerNodeNames
unset workerIps
unset mons
declare -A workerNodeNames
declare -A workerIps
declare -A mons

checkDeployerCSV() {
  echo -e "\nWaiting for ocs-osd-deployer to come in Succeeded phase"
  while true
  do
    csvStatus=$(kubectl get csv | grep ocs-osd-deployer | awk '{ print $7; exit }')
    echo "csvStatus is "$csvStatus
    if [[ $csvStatus == *"Succeeded"* ]]
    then
          break
    fi
    sleep 45
  done
}

deleteResources() {
  # Delete the resources on new provider cluster
  echo "Stopping rook-ceph operator"
  kubectl scale deployment rook-ceph-operator --replicas 0

  echo "Removing all deployments expect rook-ceph-operator"
  kubectl delete deployments -l rook_cluster=openshift-storage

  echo "Patching the secrets to remove finalizers"
  kubectl patch secret rook-ceph-mon -p '{"metadata":{"finalizers":null}}' --type=merge

  echo "Deleting the secrets which are needs to be configured"
  kubectl delete secret rook-ceph-mon
  kubectl delete secret rook-ceph-admin-keyring
  kubectl delete secret rook-ceph-mons-keyring

  echo "Deleting the osd prepare jobs if any"
  kubectl delete jobs -l app=rook-ceph-osd-prepare

  echo "Removing all PVC & PV from the namespace"
  kubectl delete pvc --all
}

applyPersistentVolumes() {

  # Apply the PV objects from the backup cluster
  echo -e "\nApplying the PVs from backup cluster "
  pvFilenames=`ls  $backupDirectoryName/persistentvolumes/`
  for pv in $pvFilenames
  do
    namespace=$(cat $backupDirectoryName/persistentvolumes/$pv | jq '.spec .claimRef .namespace' | sed "s/\"//g")
    if [[ $namespace == "openshift-storage" ]]
    then
        # claim gets added after applying pvc
        cat <<< $(jq 'del(.spec .claimRef)' $backupDirectoryName/persistentvolumes/$pv ) > $backupDirectoryName/persistentvolumes/$pv
        kubectl apply -f $backupDirectoryName/persistentvolumes/$pv
    fi
  done
}

applyPersistentVolumeClaims() {

  # Apply the PVC objects from the backup cluster
  echo -e "\nApplying PVC's for osd's and mon's"
  pvcFilenames=`ls  $backupDirectoryName/persistentvolumeclaims/*{default,rook-ceph-mon}*`
  for pvc in $pvcFilenames
  do
    # replace with cephcluster uid
    cat <<< $(jq --arg uid $uid '.metadata .ownerReferences[0] .uid=$uid' $pvc) > $pvc
    kubectl apply -f $pvc
  done

}

applySecrets() {

  # Apply the secrets
  echo -e "\nApplying required secrets for rook-ceph"
  secretFilenames=`ls  $backupDirectoryName/secrets/*{rook-ceph-mon.json,rook-ceph-mons-keyring,rook-ceph-admin-keyring}*`
  for secret in $secretFilenames
  do
    # replace with cephcluster uid
    cat <<< $(jq --arg uid $uid '.metadata .ownerReferences[0] .uid=$uid' $secret) > $secret
    kubectl apply -f $secret
  done

}

applyMonDeploymens() {

  echo "Apply the mon deployments from backup"
  deployments=`ls  $backupDirectoryName/deployments/rook-ceph-mon*`
  for entry in $deployments
  do
    monName=${entry##*/}
    monName=$(echo $monName| cut -d'-' -f 4)
    monName=${monName[0]%%.*}
    # ownerReference gets added after starting rook-ceph-operator
    cat <<< $(jq 'del(.metadata .ownerReferences)' $entry) > $entry
    cat <<< $(jq --arg workerNodeName ${workerNodeNames[$monName]} '.spec .template .spec .nodeSelector ."kubernetes.io/hostname" = $workerNodeName ' $entry) > $entry
    kubectl apply -f $entry
  done

}

injectMonMap() {

  echo "Inject monmap for mons"
  ROOK_CEPH_MON_HOST=$(kubectl get secrets rook-ceph-config -o json | jq -r '.data .mon_host' | base64 -d)
  ROOK_CEPH_MON_INITIAL_MEMBERS=$(kubectl get secrets rook-ceph-config -o json | jq -r '.data .mon_initial_members' | base64 -d)

  deployments=`ls  $backupDirectoryName/deployments/rook-ceph-mon*`
  for entry in $deployments
  do
    mon=${entry##*/}
    mon=${mon[0]%%.*}
    monName=$(echo $mon| cut -d'-' -f 4)
    publicIp="--public-addr=${workerIps[$monName]}"
    echo -e "PublicIP: "${publicIp}
    echo -e "\nBacking up mon deployemnt "$mon

    kubectl get deployments ${mon} -o json > ${mon}.json
    sleep 2
    cat <<< $(jq 'del(.spec .template  .spec .containers[0] .args[]|select(. | contains("--public-addr")))' ${mon}.json) > ${mon}.json
    cat <<< $(jq --arg publicIp $publicIp '.spec .template  .spec .containers[0] .args +=[$publicIp]' ${mon}.json ) > ${mon}.json

    echo -e "\nWaiting for mon "$monName" pod to come in crashbackloop status"
    while true
    do
      podStatus=$(kubectl get pods | grep $mon | awk '{ print $3; exit }')
      echo "podStatus is "$podStatus
      if [[ $podStatus == *"CrashLoopBackOff"* ]]
      then
            break
      fi
      sleep 2
    done

    echo -e "\nApplying Sleep, Initial delay to mon pod so that it won't restart during injecting monmap"
    kubectl patch deployment $mon -p '{"spec": {"template": {"spec": {"containers": [{"name": "mon", "livenessProbe": { "initialDelaySeconds": 20, "timeoutSeconds": 60} , "command": ["sleep", "infinity"], "args": [] }]}}}}'

    sleep 10

    podName=$(kubectl get pods | grep $mon | awk '{ print $1; exit }')

    args=$(cat $mon.json | jq -r ' .spec .template  .spec .containers[0] .args | join(" ") ')
    args="${args//)/' '}"
    args="${args//'$'(/'$'}"

    extractMonmap=$args" --extract-monmap=/tmp/monmap "
    injectMonmap=$args" --inject-monmap=/tmp/monmap "

    echo "extractMonmap: "${extractMonmap}
    echo "injectMonmap: "${injectMonmap}

    echo -e "\nWaiting for mon "$monName" pod to come in Running status"
    while true
    do
      podStatus=$(kubectl get pods | grep $mon | awk '{ print $3; exit }')
      containerCount=$(kubectl get pods | grep $mon | awk '{ print $2; exit }')
      echo "podStatus is "$podStatus
      if [[ $podStatus == *"Running"* ]]
      then
          break
      fi
      sleep 2
    done

    kubectl exec -it ${podName} -- /bin/bash -c " cluster_namespace=openshift-storage ; ceph-mon $extractMonmap ;  monmaptool --print /tmp/monmap ; monmaptool /tmp/monmap --rm ${mons[1]} ;  monmaptool /tmp/monmap --rm ${mons[2]} ; monmaptool /tmp/monmap --rm ${mons[3]} ; monmaptool /tmp/monmap --add ${mons[1]} ${workerIps[${mons[1]}]} ; monmaptool /tmp/monmap --add ${mons[2]} ${workerIps[${mons[2]}]} ; monmaptool /tmp/monmap --add ${mons[3]} ${workerIps[${mons[3]}]} ; sleep 2 ; ceph-mon $injectMonmap ; monmaptool --print /tmp/monmap ; sleep 2"

    sleep 5

    echo -e "\napplying rook ceph mon deployment"
    kubectl replace --force -f $mon.json
  done

}

updateConfigMap() {

  # ConfigMap
  echo -e "\nUpdating configmap to new Data & mapping"
  kubectl get configmaps rook-ceph-mon-endpoints -o yaml > rook-ceph-mon-endpoints.yaml

  data=""
  mapping=""
  for mon in "${mons[@]}";
  do
    data+=","${mon}"="${workerIps[$mon]}":6789"
    mapping+=",\"${mon}\":{\"Name\":\"${workerNodeNames[$mon]}\",\"Hostname\":\"${workerNodeNames[$mon]}\",\"Address\":\"${workerIps[$mon]}\"}"
  done
  export data=${data:1}
  cat <<< $(yq e '.data .data = env(data)' rook-ceph-mon-endpoints.yaml ) > rook-ceph-mon-endpoints.yaml
  echo ${data}
  export mapping="'{\"node\":{${mapping:1}}}'"
  echo ${mapping}
  cat <<< $(yq e '.data .mapping = env(mapping)' rook-ceph-mon-endpoints.yaml ) > rook-ceph-mon-endpoints.yaml
  kubectl apply -f rook-ceph-mon-endpoints.yaml

}

checkMonStatus() {
  # Wait for all the mons to come up
  echo -e "\nWaiting for all the mon's pod to come in Running status and expected mon container count to be available"
  for mon in "${mons[@]}";
  do
    while true
    do
      podStatus=$(kubectl get pods | grep rook-ceph-mon-${mon} | awk '{ print $3; exit }')
      containerCount=$(kubectl get pods | grep rook-ceph-mon-${mon} | awk '{ print $2; exit }')
      echo "for mon "${mon}" podStatus is "$podStatus" containerCount is "$containerCount
      if [[ $podStatus == *"Running"* && $containerCount == "2/2" ]]
      then
          break
      fi
      sleep 2
    done
  done
}

applyOsds() {

  # Iterate over the OSD deployment files
  echo -e "\nApplying the deployments for osds"
  deploymentsOsds=`ls  $backupDirectoryName/deployments/rook-ceph-osd-*`
  for entry in $deploymentsOsds
  do
    # ownerReference gets added after starting rook-ceph-operator
    cat <<< $(jq 'del(.metadata .ownerReferences)' $entry) > $entry
    kubectl apply -f $entry
  done

}

applyStorageConsumers() {

  # Get the names of all the storage consumer files in the backup directory and apply them
  echo -e "\nApplying Storage consumer CR"
  consumers=`ls  $backupDirectoryName/storageconsumers`
  for entry in $consumers
  do
    echo "applying Consumer with name: "$entry
    kubectl apply -f $backupDirectoryName/storageconsumers/$entry
  done

}

validateClusterRequirement() {

  # Check if the openshift-storage namespace exists
  echo "Checking if the namespace openshift-storage exist"
  if kubectl get namespaces openshift-storage &> /dev/null; then
    echo "Namespace exists!"
  else
    echo "Namespace does not exist! Exiting.."
    cleanup
    exit
  fi

  echo "Switching to the openshift-storage namespace"
  kubectl config set-context --current --namespace=openshift-storage

  # Check if the cluster is a provider cluster
  echo "Checking if it's a provider cluster"
  if kubectl get deployments ocs-osd-controller-manager &> /dev/null; then
    addOn=$(kubectl get deployments ocs-osd-controller-manager -o json | jq -r '.spec .template .spec .containers[] .env[0]|select(. | .name == "ADDON_NAME") .value')
    if [[ $addOn == *"provider"* ]]; then
      echo "It is a provider cluster!"
    else
      echo "Not a provider cluster! Exiting.."
      cleanup
      exit
    fi
  else
    echo "ocs-osd-controller-manager deployment not found! Exiting.."
    cleanup
    exit
  fi

}

prepareData() {

  echo -e "\nPreparing data"
  echo -e "\nMapping monName to nodeName and nodeIP"
  for nodeNumber in {1..3};
  do
    pvName=$(kubectl get pvc | grep rook-ceph-mon | awk -v nodeNumber=$nodeNumber '{ awkArray[NR] = $3} END { print awkArray[nodeNumber];}')
    pvZone=$(kubectl get pv $pvName -ojson | jq '.metadata .labels ."topology.kubernetes.io/zone"' | sed "s/\"//g")
    monName=$(kubectl get pv $pvName -ojson | jq '.spec .claimRef .name'   | sed "s/\"//g" | cut -d'-' -f 4)
    mons[$nodeNumber]=$monName

    nodeName=$(kubectl get nodes -owide --selector=topology.kubernetes.io/zone=$pvZone | grep worker | grep -v infra | awk '{print $1; exit}')
    nodeIP=$(kubectl get nodes -owide --selector=topology.kubernetes.io/zone=$pvZone | grep worker | grep -v infra | awk '{print $6; exit}')
    workerNodeNames[$monName]=$nodeName
    workerIps[$monName]=$nodeIP
  done

}


backupDirectoryName=backup

validateClusterRequirement

checkDeployerCSV

deleteResources

applyPersistentVolumes

uid=$(kubectl get cephcluster ocs-storagecluster-cephcluster -o json | jq -r  '.metadata .uid')

applyPersistentVolumeClaims

applySecrets

prepareData

applyMonDeploymens

injectMonMap

updateConfigMap

checkMonStatus

applyOsds

echo -e "\nScaling up the rook ceph operator"
kubectl scale deployment rook-ceph-operator --replicas 1

sleep 60
checkDeployerCSV

echo -e "\nRestart the rook ceph tools pod"
kubectl rollout restart deployment rook-ceph-tools

applyStorageConsumers

version=$(kubectl get csv $(kubectl get csv -n openshift-storage | grep odf-operator | awk '{print $1; exit}') -n openshift-storage -ojson | jq -r '.spec .version')
# patching the storageCluster to add the necessary fields to migrate to odf 4.12
if [[ ${version:0:4} == "4.12" ]]; then
  kubectl patch storagecluster ocs-storagecluster -p '{"spec":{ "defaultStorageProfile":"default", "storageProfiles": [{"deviceClass":"ssd","name":"default"}] }}' --type=merge
fi

echo -e "\nRestart the ocs provider server pod"
kubectl rollout restart deployment ocs-provider-server

# Get the storage provider endpoint from the Kubernetes API and print it
storageProviderEndpoint=$(kubectl get StorageCluster ocs-storagecluster -o json | jq -r '.status .storageProviderEndpoint')
echo "Storage Provider endpoint: ${storageProviderEndpoint}"
