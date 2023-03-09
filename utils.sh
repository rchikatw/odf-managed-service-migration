#!/bin/bash

unset link
declare -A link

link[jq]="https://www.cyberithub.com/how-to-install-jq-json-processor-on-rhel-centos-7-8/"
link[yq]="https://www.cyberithub.com/how-to-install-yq-command-line-tool-on-linux-in-5-easy-steps/"
link[ocm]="https://console.redhat.com/openshift/downloads"
link[kubectl]="https://kubernetes.io/docs/tasks/tools/"
link[rosa]="https://console.redhat.com/openshift/downloads"
link[aws]="https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
link[curl]="https://curl.se/download.html"
link[ocm-backplane]="https://gitlab.cee.redhat.com/service/backplane-cli"

loginCluster() {
  if [[ "${1}" == "-d" ]];
  then
  storeKubeconfigAndLoginCluster $2
  else
  ocm-backplane login $1
  fi
}

storeKubeconfigAndLoginCluster() {
  mkdir -p kubeconfig

  response=$(ocm get /api/clusters_mgmt/v1/clusters/${1}/credentials 2>&1)
  kind=$(echo $response | jq .kind | sed "s/\"//g")
  if [[ $kind == "ClusterCredentials" ]]; then
    echo "Cluster id found, getting kubeconfig"
    ocm get /api/clusters_mgmt/v1/clusters/${1}/credentials | jq -r .kubeconfig > kubeconfig/${1}
    export KUBECONFIG=$(readlink -f kubeconfig/${1})
  else
    echo $response | jq .reason | sed "s/\"//g"
    exit
  fi
}

validate() {
  for var in "$@"
  do
    if hash $var 2>/dev/null; then
        echo "OK, you have $var installed. We will use that."
    else
        echo "$var is not installed, Please install and re-run the script again"
        echo "To download $var cli, refer ${link[$var]}"
        exit
    fi
  done

}

cleanup() {
  echo "Cleaning up..."
  # unset the arrays
  unset workerNodeNames
  unset workerIps
  unset mons
  unset link
  unset storageConsumerUID

  # Remove the backup and temporary files
  rm -rf backup
  rm -rf s3backup
  rm -rf kubeconfig
  rm -f rook-ceph-mon-*.json
  rm -f rook-ceph-mon-endpoints.yaml
}
