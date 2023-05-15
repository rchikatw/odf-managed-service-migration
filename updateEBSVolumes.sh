#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Update EBS volume name and tags for backup cluster.

  Requirements:
    1. kubectl, AWS cli and jq installed.
    2. access to aws account from cli where volume's are available.
    3. kubectl: ${link[kubectl]}
    4. jq: ${link[jq]}
    5. aws: ${link[aws]}

  USAGE: "./updageEBSVolumeTags.sh <newClusterID> -d"

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

loginCluster $1 $2 $3

echo -e "${Green}Update EBS volume tags started${EndColor}"

pvNames=( $(kubectl get pv | grep openshift-storage | awk 'print $1') )
namespaceKey="kubernetes.io/created-for/pvc/namespace"
for pvName in $pvNames
do
  volumeID=$(kubectl get pv $pvName -ojson | jq -r '.spec .awsElasticBlockStore .volumeID |  split("/") | .[-1]')
  echo -e "${Cyan}Updating tags and storageClass for volume Id ${EndColor}"$volumeID
  region=$(kubectl get pv $pvName -ojson | jq -r '.metadata .labels ."topology.kubernetes.io/region"')
  keyName=$(aws ec2 describe-volumes --volume-id $volumeID --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=openshift-storage  --region $region --query "Volumes[*].Tags" --output json --profile migration | jq .[] | jq -r '.[]| select (.Value == "owned")|.Key')
  backupKeyName=${keyName##*/}
  aws ec2 delete-tags --tags Key=$keyName --resources $volumeID --region $region --profile migration

  #Update the tag with correct key
  keyName="kubernetes.io/cluster/"$(ocm describe cluster $1 --json | jq -r '.infra_id')
  aws ec2 create-tags --tags Key=$keyName,Value=owned --resources $volumeID --region $region --profile migration

  nameValue=$(aws ec2 describe-volumes --volume-id $volumeID --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=openshift-storage  --region $region --query "Volumes[*].Tags" --output json --profile migration | jq .[] | jq -r '.[]| select (.Key == "Name")|.Value')
  restoreKeyName=${keyName##*/}
  restoreValue=${nameValue/$backupKeyName/$restoreKeyName}
  aws ec2 create-tags --tags Key=Name,Value=$restoreValue --resources $volumeID --region $region --profile migration

  aws ec2 create-tags --tags Key=$namespaceKey,Value=$dfOfferingNamespace --resources $volumeID --region $region --profile migration
  
  #Update the volume type to gp3
  claimName=$(kubectl get pv ${pvName} -ojson | jq -r '.spec .claimRef .name')
  if [[ "$claimName" == *"rook-ceph-mon"* ]]; then
    aws ec2 modify-volume --volume-type gp3 --volume-id $volumeID --region $region --profile migration
  elif [[ "$claimName" == *"default"* ]]; then
    aws ec2 modify-volume --volume-type gp3 --iops 12000 --throughput 250 --volume-id $volumeID --region $region --profile migration
  fi
done

echo -e "${Green}Finished Updating EBS volume tags ${EndColor}"

