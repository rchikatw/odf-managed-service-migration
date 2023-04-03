#!/bin/bash

usage() {
  cat << EOF

  Sample Script to verify, modify, scale and populate data in applications

  USAGE: "./dataOps.sh <verify|populate|modify|scale> <Number of applications> [scale - Number of replcias]"
EOF
}

if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

namespaces=()

rbd="sample-app-rbd"
fs="sample-app-fs"

for (( i=1; i<=$2; i++ ))
do
  namespaces+=($rbd$i)
  namespaces+=($fs$i)
done

printf '%s\n' "${namespaces[@]}"

exit

case "$1" in
  verify)
    for ns in "${namespaces[@]}"
    do
      echo $ns
      podName=$(kubectl get pods -n ${ns} --no-headers | awk '{print $1}')
      kubectl exec -it ${podName} -n ${ns} -- /bin/bash -c "cd /usr/share/nginx/html; ls; cat name; sleep 2"
    done
    ;;
  modify)
    for ns in "${namespaces[@]}"
    do
      echo $ns
      podName=$(kubectl get pods -n ${ns} --no-headers | awk '{print $1}')
      kubectl exec -it ${podName} -n ${ns} -- /bin/bash -c "cd /usr/share/nginx/html; ls; rm testfile13;dd if=/dev/zero of=testfile15 bs=1024 count=102400; sleep 2; ls"
    done
    ;;
  populate)
    for ns in "${namespaces[@]}"
    do
      echo $ns
      podName=$(kubectl get pods -n ${ns} --no-headers | awk '{print $1}')
      kubectl exec -it ${podName} -n ${ns} -- /bin/bash -c "cd /usr/share/nginx/html; dd if=/dev/zero of=testfile12 bs=1024 count=102400; dd if=/dev/zero of=testfile13 bs=1024 count=102400; dd if=/dev/zero of=testfile14 bs=1024 count=102400; echo Hello! Rewant > name; sleep 4"
    done
    ;;
  scale)
    for ns in "${namespaces[@]}"
    do
      dn=$(kubectl get deployment -n ${ns} --no-headers | awk '{print $1}')
      kubectl scale deployment $dn -n ${ns} --replicas $3
    done
    ;;
  *)
    echo "Invalid Option, exiting..."
    exit
esac