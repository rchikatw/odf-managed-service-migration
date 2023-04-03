#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Restore a ODF MS provider into a new cluster.

  Requirements:
    1. A new ROSA cluster with ODF MS Provider addon installed.
    2. Backup of resources from the old cluster.
    3. kubectl, yq and jq installed.

  USAGE: "./restoreProvider.sh"

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

validateClusterRequirement() {

  # Check if the openshift-storage namespace exists
  echo -e "${Green}\nChecking if the namespace openshift-storage exist"
  if kubectl get namespaces openshift-storage &> /dev/null; then
    echo -e "${Cyan}\nNamespace exists!"
  else
    echo "${Red}Namespace does not exist! Exiting.."
    cleanup
    exit
  fi

  echo -e "${Cyan}\nSwitching to the openshift-storage namespace"
  kubectl config set-context --current --namespace=openshift-storage

}

checkDeployerCSV() {
  echo -e "\nWaiting for managed-fusion to come in Succeeded phase"
  while true
  do
    csvStatus=$(kubectl get csv | grep managed-fusion | awk '{ print $6; exit }')
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
  echo -e "\n{Cyan}Applying the PVs from backup cluster "
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
  echo -e "\n{Cyan}Applying PVC's for osd's and mon's"
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
  echo -e "\n{Cyan}Applying required secrets for rook-ceph"
  secretFilenames=`ls  $backupDirectoryName/secrets/*{rook-ceph-mon.json,rook-ceph-mons-keyring,rook-ceph-admin-keyring}*`
  for secret in $secretFilenames
  do
    # replace with cephcluster uid
    cat <<< $(jq --arg uid $uid '.metadata .ownerReferences[0] .uid=$uid' $secret) > $secret
    kubectl apply -f $secret
  done

}

prepareData() {

  echo -e "\n{Cyan}Preparing data, Mapping monName to nodeName and nodeIP"
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

applyMonDeploymens() {

  echo -e "\n{Cyan}Apply the mon deployments from backup"
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

  echo -e "\n{Cyan}Inject monmap for mons"
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

    echo -e "\n{Cyan}Waiting for mon "$monName" pod to come in crashbackloop status"
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

    echo -e "\n{Cyan}Applying Sleep, Initial delay to mon pod so that it won't restart during injecting monmap"
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

    echo -e "\n{Cyan}Waiting for mon "$monName" pod to come in Running status"
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

    echo -e "\n{Cyan}applying rook ceph mon deployment"
    kubectl replace --force -f $mon.json
  done

}

updateConfigMap() {

  # ConfigMap
  echo -e "\n{Cyan}Updating configmap to new Data & mapping"
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
  echo -e "\n{Cyan}Waiting for all the mon's pod to come in Running status and expected mon container count to be available"
  for mon in "${mons[@]}";
  do
    while true
    do
      podStatus=$(kubectl get pods | grep rook-ceph-mon-${mon} | awk '{ print $3; exit }')
      containerCount=$(kubectl get pods | grep rook-ceph-mon-${mon} | awk '{ print $2; exit }')
      echo -e "\n{Cyan}for mon "${mon}" podStatus is "$podStatus" containerCount is "$containerCount
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
  echo -e "\n{Cyan}Applying the deployments for osds"
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
  echo -e "\n{Cyan}Applying Storage consumers"
  consumers=`ls  $backupDirectoryName/storageconsumers`
  for entry in $consumers
  do
    echo "{Cyan}applying Consumer with name: "$entry
    kubectl apply -f $backupDirectoryName/storageconsumers/$entry
    sleep 5

    status=$(jq '.status' $backupDirectoryName/storageconsumers/$entry)
    cosnumer=${entry[0]%%.*}
    kubectl patch --subresource=status storageconsumer ${cosnumer} --type=merge --patch "{\"status\": ${status} }"
  done

}

applyStorageClassClaim() {

  echo -e "\n{Cyan}Applying StorageClassClaims"
  storageConsumers=( $(kubectl get storageConsumers -n openshift-storage --no-headers | awk '{print $1}') )
  for storageConsumer in ${storageConsumers[@]}
  do
    newUID=$(kubectl get storageconsumer ${storageConsumer} -n openshift-storage -ojson | jq -r '.metadata .uid')
    oldUID=$(jq -r '.metadata .uid' $backupDirectoryName/storageconsumers/${storageConsumer}.json)
    sed -i 's/'${oldUID}'/'${newUID}'/g' $backupDirectoryName/storageclassclaims/storageclassclaims.json
    sed -i 's/'${oldUID}'/'${newUID}'/g' $backupDirectoryName/cephclients/cephclients.json
  done

  # updated the name to new md5 sum of UID+claimName
  # https://github.com/red-hat-storage/ocs-operator/blob/208b1824cae9b5e0c8288ddddb5b780a3fdf546d/services/provider/server/storageclaim.go#L56-L127

  count=`jq '.items | length' $backupDirectoryName/storageclassclaims/storageclassclaims.json`
  for ((i=0; i<$count; i++)); do
    consumerClaimName=`jq -r '.items['$i'] .metadata .labels ."ocs.openshift.io/storageclassclaim-name"' $backupDirectoryName/storageclassclaims/storageclassclaims.json`
    uid=`jq -r '.items['$i'] .metadata .labels ."ocs.openshift.io/storageconsumer-uuid"' $backupDirectoryName/storageclassclaims/storageclassclaims.json`

    json=$(echo {\"storageConsumerUUID\":\"$uid\"\,\"storageClassClaimName\":\"$consumerClaimName\"})
    generatedName=$(echo -n $json | md5sum | awk '{print $1}')
    newClaimName="storageclassclaim-"$generatedName
    oldClaimName=`jq -r '.items['$i'] .metadata .name' $backupDirectoryName/storageclassclaims/storageclassclaims.json`

    sed -i 's/'${oldClaimName}'/'${newClaimName}'/g' $backupDirectoryName/storageclassclaims/storageclassclaims.json
    sed -i 's/'${oldClaimName}'/'${newClaimName}'/g' $backupDirectoryName/cephclients/cephclients.json
  done

  kubectl apply -f $backupDirectoryName/storageclassclaims/storageclassclaims.json
  sleep 5

  storageClassClaims=( $(kubectl get storageClassClaims -n openshift-storage --no-headers | awk '{print $1}') )
  for storageClassClaim in ${storageClassClaims[@]}
  do
    status=$(jq '.items[] | select(.metadata .name == "'${storageClassClaim}'") | .status' $backupDirectoryName/storageclassclaims/storageclassclaims.json)
    kubectl patch --subresource=status storageclassclaim ${storageClassClaim} -n openshift-storage --type=merge --patch "{\"status\": ${status} }"
  done
}

applyCephClients() {

  echo "{Cyan}Applying CephClients"

  storageClassClaims=( $(kubectl get storageClassClaims -n openshift-storage --no-headers | awk '{print $1}') )
  for storageClassClaim in ${storageClassClaims[@]}
  do
    oldUID=`jq -r --arg scc $storageClassClaim '.items[] .metadata .ownerReferences[0] | select( .name==$scc) | .uid' $backupDirectoryName/cephclients/cephclients.json | awk '{print $1; exit}'`
    newUID=`kubectl get storageclassclaim $storageClassClaim -n openshift-storage -ojson | jq -r '.metadata .uid'`
    sed -i 's/'${oldUID}'/'${newUID}'/g' $backupDirectoryName/cephclients/cephclients.json
  done

  kubectl apply -f $backupDirectoryName/cephclients/cephclients.json
  sleep 5

  cephclients=( $(kubectl get cephclient -n openshift-storage --no-headers | awk '{print $1}') )
  for cephclient in ${cephclients[@]}
  do
    status=$(jq '.items[] | select(.metadata .name == "'${cephclient}'") | .status' $backupDirectoryName/cephclients/cephclients.json)
    kubectl patch --subresource=status cephclient ${cephclient} -n openshift-storage --type=merge --patch "{\"status\": ${status} }"
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

echo -e "\n{Cyan}Scaling up the rook ceph operator"
kubectl scale deployment rook-ceph-operator --replicas 1

sleep 60
checkDeployerCSV

echo -e "\n{Cyan}Restart the rook ceph tools pod"
kubectl rollout restart deployment rook-ceph-tools

# scale down ocs
kubectl scale deployment ocs-operator --replicas 0
kubectl scale deployment ocs-provider-server --replicas 0

applyStorageConsumers

applyStorageClassClaim

applyCephClients

# scale up ocs
kubectl scale deployment ocs-operator --replicas 1
kubectl scale deployment ocs-provider-server --replicas 1

# Get the storage provider endpoint from the Kubernetes API and print it
storageProviderEndpoint=$(kubectl get StorageCluster ocs-storagecluster -o json | jq -r '.status .storageProviderEndpoint')
echo "{Green}Storage Provider endpoint ==>: ${storageProviderEndpoint}"
