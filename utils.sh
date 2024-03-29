#!/bin/bash

unset link
declare -A link

link[jq]="https://www.cyberithub.com/how-to-install-jq-json-processor-on-rhel-centos-7-8/"
link[yq]="https://www.cyberithub.com/how-to-install-yq-command-line-tool-on-linux-in-5-easy-steps/"
link[ocm]="https://console.redhat.com/openshift/downloads"
link[rosa]="https://console.redhat.com/openshift/downloads"
link[kubectl]="https://kubernetes.io/docs/tasks/tools/"
link[aws]="https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
link[ocm-backplane]="https://gitlab.cee.redhat.com/service/backplane-cli"

dfOfferingNamespace="fusion-storage"
clientOperatorNamespace="fusion-storage"
storageClientName="ocs-storageclient"
oldOCMToken=""
newOCMToken="" 

Red='\033[1;31m'          # Red
Green='\033[1;32m'        # Green
Cyan='\033[0;36m'         # Cyan
EndColor='\e[0m'
BoldCyan='\033[1;36m'
Blue='\033[1;34m'          # Blue

loginCluster() {
  if [[ "${2}" == "-d" ]];
  then
    ocm login --token="$3" --url=staging
    storeKubeconfigAndLoginCluster $1
  elif [ -z "${2}" ];then
    ocm-backplane login $1
  else
    echo -e "\n${Red}Invalid Option ${EndColor}"$1
  fi
}

storeKubeconfigAndLoginCluster() {
  mkdir -p kubeconfig

  response=$(ocm get /api/clusters_mgmt/v1/clusters/${1}/credentials 2>&1)
  kind=$(echo $response | jq .kind | sed "s/\"//g")
  if [[ $kind == "ClusterCredentials" ]]; then
    echo -e "${Cyan}Cluster ID found, getting kubeconfig${EndColor}"
    ocm get /api/clusters_mgmt/v1/clusters/${1}/credentials | jq -r .kubeconfig > kubeconfig/${1}
    export KUBECONFIG=$(readlink -f kubeconfig/${1})
  else
    echo $response | jq .reason | sed "s/\"//g"
    exit 1
  fi
}

validate() {
  for var in "$@"
  do
    if !(hash $var 2>/dev/null); then
      echo -e "${Red}$var is not installed, Please install and re-run the script again, To download $var cli, refer "${EndColor} "${Cyan}${link[$var]}${EndColor}"
      exit 1
    fi
  done
}

validateKubectlVersion() {
  kubectl version -o json > kubedetails.json
  clientMajor=$(cat kubedetails.json | jq -r '.clientVersion .major')
  serverMajor=$(cat kubedetails.json | jq -r '.serverVersion .major')
  clientMinor=$(cat kubedetails.json | jq -r '.clientVersion .minor')
  serverMinor=$(cat kubedetails.json | jq -r '.serverVersion .minor')
  rm kubedetails.json
  if [[ "$clientMajor" < "1" ||  "$serverMajor" < "1" || "$clientMinor" < "24" ||  "$serverMinor" < "24" ]]; then  
    echo -e "${Red}Error: Please update the kubectl version to >= 1.24${EndColor}"
    exit 1
  fi
}

cleanup() {
  # unset the arrays
  unset workerNodeNames
  unset workerIps
  unset mons
  unset link
  unset storageConsumerUID

  # Remove the backup and temporary files
  rm -rf backup
  rm -rf backup_consumer
  rm -rf s3backup
  rm -rf kubeconfig
  rm -rf rook-ceph-mon-*.json
  rm -rf rook-ceph-mon-endpoints.yaml
  rm -rf ocs-storagecluster-*.yaml
}
