#!/bin/bash
source ./utils.sh

usage() {
  cat << EOF

  Update EBS volume name and tags for backup cluster.

  Requirements:
    1. backup of resources from the old cluster.
    2. kubectl, AWS cli and jq installed.
    3. access to aws account from cli where volume's are available.

  USAGE: "./updageEBSVolumeTags.sh"

  To install kubectl, jq & aws CLI Refer:
  1. kubectl: ${link[kubectl]}
  2. jq: ${link[jq]}
  3. aws: ${link[aws]}

EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

echo "${Green}Update EBS volume tags started${EndColor}"

pvFilenames=`ls  backup/persistentvolumes/`
for pv in $pvFilenames
do
  volumeID=$(cat backup/persistentvolumes/$pv | jq -r '.spec .awsElasticBlockStore .volumeID |  split("/") | .[-1]')
  echo -e "Updating tags for volume Id "$volumeID
  region=$(cat backup/persistentvolumes/$pv | jq -r '.metadata .labels ."topology.kubernetes.io/region"')
  keyName=$(aws ec2 describe-volumes --volume-id $volumeID --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=openshift-storage  --region $region --query "Volumes[*].Tags" | jq .[] | jq -r '.[]| select (.Value == "owned")|.Key')
  backupKeyName=${keyName##*/}
  aws ec2 delete-tags --tags Key=$keyName --resources $volumeID --region $region

  #Update the tag with correct key
  keyName="kubernetes.io/cluster/"$(kubectl get machineset $(kubectl get machineset -n openshift-machine-api | awk 'NR!=1 {print}' | awk '{ print $1; exit }') -n openshift-machine-api -o json | jq -r '.metadata .labels ."machine.openshift.io/cluster-api-cluster"')
  aws ec2 create-tags --tags Key=$keyName,Value=owned --resources $volumeID --region $region

  nameValue=$(aws ec2 describe-volumes --volume-id $volumeID --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=openshift-storage  --region $region --query "Volumes[*].Tags" | jq .[] | jq -r '.[]| select (.Key == "Name")|.Value')
  restoreKeyName=${keyName##*/}
  restoreValue=${nameValue/$backupKeyName/$restoreKeyName}
  aws ec2 create-tags --tags Key=Name,Value=$restoreValue --resources $volumeID --region $region
done

echo "${Green} Finished Updating EBS volume tags ${EndColor}"
