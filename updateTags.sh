#!/bin/bash
usage() {
  cat << EOF
 
  Update volume tags for backup cluster.
 
  Requirements:
    1. Backup of resources from the old cluster.
    2. aws cli and jq installed.
    3. access to aws account from cli where volume's are available.
 
  USAGE: "./updateTags.sh "
 
  To install jq & aws CLI Refer:
  1. jq: https://www.cyberithub.com/how-to-install-jq-json-processor-on-rhel-centos-7-8/
  2. aws: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
 
EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

if hash jq 2>/dev/null; then
  echo "OK, you have jq installed. We will use that."
else
  echo "jq is not installed, Please install and rerun the restore script"
  usage
  exit
fi

if hash aws 2>/dev/null; then
  echo "OK, you have aws CLI installed. We will use that."
else
  echo "aws CLI is not installed, Please install and rerun the restore script"
  usage
  exit
fi

echo -e "\nFetching volumeIds "

pvFilenames=`ls  backup/persistentvolumes/`
for pv in $pvFilenames
do
  volumeId=$(cat backup/persistentvolumes/$pv | jq -r '.spec .awsElasticBlockStore .volumeID |  split("/") | .[-1]')
  echo -e "\nUpdating tags for volumeId "$volumeId
  region=$(cat backup/persistentvolumes/$pv | jq -r '.metadata .labels ."topology.kubernetes.io/region"')
  keyName=$(aws ec2 describe-volumes --volume-id $volumeId --filters Name=tag:Name,Values=rchikatw-osd* Name=tag:kubernetes.io/created-for/pvc/namespace,Values=openshift-storage  --region $region --query "Volumes[*].Tags" | jq .[] | jq -r '.[]| select (.Value == "owned")|.Key')
  aws ec2 delete-tags --tags Key=$keyName --resources $volumeId --region $region
  keyName=$keyName"test"
  #Update the tag with correct key
  #kubectl get machine rchikatw-osd-bt9zt-infra-us-east-1a-278lr -n openshift-machine-api -o json | jq -r '.metadata .labels ."machine.openshift.io/cluster-api-cluster"'
  aws ec2 create-tags --tags Key=$keyName,Value=owned --resources $volumeId --region $region
  echo -e "\nUpdated tags for volumeId "$volumeId
  exit
done
