#!/bin/bash

usage() {
  cat << EOF

  Sample Script to create applications

  USAGE: "./create-sample-applications.sh <Number of applications>"
EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

for (( i=1; i<=$1; i++ ))
do

  echo $i

  sed -i 's/fs1/fs'${i}'/g' examples/sample-applications/cephfs.yaml
  sed -i 's/rbd1/rbd'${i}'/g' examples/sample-applications/cephrbd.yaml

  kubectl apply -f examples/sample-applications/cephfs.yaml
  kubectl apply -f examples/sample-applications/cephrbd.yaml

  sed -i 's/fs'${i}'/fs1/g' examples/sample-applications/cephfs.yaml
  sed -i 's/rbd'${i}'/rbd1/g' examples/sample-applications/cephrbd.yaml

done

exit

# Create data

cd /usr/share/nginx/html
dd if=/dev/zero of=testfile12 bs=1024 count=102400
dd if=/dev/zero of=testfile13 bs=1024 count=102400
dd if=/dev/zero of=testfile14 bs=1024 count=102400
dd if=/dev/zero of=testfile15 bs=1024 count=102400
echo "Hello! Rewant" > name


ns="sample-app-rbd3"
oc exec -it $(oc get pods -n ${ns} --no-headers | awk '{print $1}') -n ${ns} -- sh

rs=
oc get ${rs} --no-headers | awk '{print $1}' | xargs kubectl patch ${rs} -p '{"metadata":{"finalizers":null}}' --type=merge -n openshift-storage; oc get ${rs} --no-headers | awk '{print $1}' | xargs kubectl delete ${rs}
