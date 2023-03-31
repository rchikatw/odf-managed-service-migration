version="4.11"

if [[ "${1}" == "-p" ]] || [[ "${1}" == "--provider" ]]; then
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
 name: redhat-operators-test
 namespace: openshift-storage
spec:
 displayName: Openshift Container Storage Temp
 icon:
   base64data: ''
   mediatype: ''
 image: registry.redhat.io/redhat/redhat-operator-index:v4.12
 priority: 100
 publisher: Red Hat
 sourceType: grpc
 updateStrategy:
   registryPoll:
     interval: 15m
EOF
version="4.12"
else
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
 name: redhat-operators-test
 namespace: openshift-storage
spec:
 displayName: Openshift Container Storage Temp
 icon:
   base64data: ''
   mediatype: ''
 image: registry.redhat.io/redhat/redhat-operator-index:v4.11
 priority: 100
 publisher: Red Hat
 sourceType: grpc
 updateStrategy:
   registryPoll:
     interval: 15m
EOF
fi

cat <<EOF | oc apply -f -
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
 name: redhat-operators-test-catalogs
 namespace: openshift-storage
spec:
 podSelector:
   matchExpressions:
     - key: olm.catalogSource
       operator: In
       values:
         - redhat-operators-test
 ingress:
   - ports:
       - protocol: TCP
         port: 50051
 policyTypes:
   - Ingress
EOF

kubectl config set-context --current --namespace=openshift-storage

# "-" removes annotation
kubectl annotate csv $(kubectl get csv | grep ocs-osd | awk '{print $1; exit}') operatorframework.io/properties-
kubectl annotate csv $(kubectl get csv | grep odf-operator | awk '{print $1; exit}') operatorframework.io/properties-

kubectl patch subs $(kubectl get sub | grep odf-operator | awk '{print $1; exit}') --type=merge -p '{"spec":{"channel":"stable-'${version}'","source":"redhat-operators-test","sourceNamespace":"openshift-storage"}}'

while true
do
    csvStatus=$(kubectl get csv | grep odf-operator.v${version} | awk '{ print $7; exit }')
    echo "csvStatus is "$csvStatus
    if [[ $csvStatus == *"Succeeded"* ]]
    then
        break
    fi
    sleep 45
done

kubectl patch subs $(kubectl get sub | grep ocs-operator | awk '{print $1; exit}') --type=merge -p '{"spec":{"channel":"stable-'${version}'","source":"redhat-operators-test","sourceNamespace":"openshift-storage"}}'

kubectl patch subs $(kubectl get sub | grep mcg-operator | awk '{print $1; exit}') --type=merge -p '{"spec":{"channel":"stable-'${version}'","source":"redhat-operators-test","sourceNamespace":"openshift-storage"}}'

kubectl patch subs $(kubectl get sub | grep odf-csi-addons-operator | awk '{print $1; exit}') --type=merge -p '{"spec":{"channel":"stable-'${version}'","source":"redhat-operators-test","sourceNamespace":"openshift-storage"}}'

if [[ "${1}" == "-p" ]] || [[ "${1}" == "--provider" ]]; then
    kubectl scale deployment ocs-osd-controller-manager --replicas 0
    # patch starts working after some time, when ocs-operator is updating?
    while true
    do
      csvStatus=$(kubectl get csv | grep ocs-operator.v${version} | awk '{ print $7; exit }')
      echo "csvStatus is "$csvStatus
      if [[ $csvStatus == *"Succeeded"* ]]
      then
        break
      fi
      sleep 45
    done
    kubectl patch storagecluster ocs-storagecluster -p '{"spec":{ "defaultStorageProfile":"default", "storageProfiles": [{"deviceClass":"ssd", "name":"default", "blockPoolConfiguration":{"parameters":{"pg_autoscale_mode":"on","pg_num":"128","pgp_num":"128"}}, "sharedFilesystemConfiguration":{"parameters":{"pg_autoscale_mode":"on","pg_num":"128","pgp_num":"128"}} }] }}' --type=merge
    sleep 5
    kubectl patch storagecluster ocs-storagecluster -p '[{"op":"add", "path":"/spec/storageDeviceSets/0/deviceClass", "value":"ssd"}]' --type=json
fi
