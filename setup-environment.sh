#!/bin/bash

# **** This script runs on upstream knative ci server from ci-script which is stored in GCP. ****
# It sets up the k8s environment and updates the knative source for running the tests succesfully.


#--- Common Functions ---
create_registry_secrets_in_serving(){
    kubectl create ns knative-serving
    kubectl -n knative-serving create secret generic registry-creds --from-file=config.json=$HOME/.docker/config.json
    kubectl -n knative-serving create secret generic registry-certs --from-file=ssl.crt=/tmp/ssl.crt
}


install_contour(){
    # TODO: remove yq dependency
    wget https://github.com/mikefarah/yq/releases/download/v4.25.3/yq_linux_amd64 -P /tmp
    chmod +x /tmp/yq_linux_amd64

    echo "Contour is being installed..."
   
    envoy_replacement=registry.apps.a9367076.nip.io/maistra/envoy:v2.2
    ISTIO_RELEASE=knative-v1.0.0

     # install istio-crds
    curl --connect-timeout 10 --retry 5 -sL https://github.com/knative-sandbox/net-istio/releases/download/${ISTIO_RELEASE}/istio.yaml | \
    /tmp/yq_linux_amd64 '. | select(.kind == "CustomResourceDefinition"), select(.kind == "Namespace")' | kubectl apply -f -

    # install contour
    curl --connect-timeout 10 --retry 5 -sL https://raw.githubusercontent.com/knative/serving/release-1.1/third_party/contour-latest/contour.yaml | \
    sed 's!\(image: \).*docker.io.*!\1'$envoy_replacement'!g' | kubectl apply -f -
    kubectl apply -f https://raw.githubusercontent.com/knative/serving/main/third_party/contour-latest/net-contour.yaml
    echo "Waiting until all pods under contour-external are ready..."
    kubectl wait --timeout=5m pod --for=condition=Ready -n contour-external -l '!job-name'
}
#------------------------


# TODO: Find root cause for below
# Sometimes job fails with no host found error. Looks like /etc/hosts patching done in ci-script
# is not retained for some reason. Adding a fix for such situation.

BASE_DIR=/opt/knative-upstream-ci
K8S_POOL_DIR="/root/cluster-pool/pool/k8s"
K8S_AUTOMN_DIR=/root/k8s-ansible-automation
SSH_USER=root
SSH_HOST="a9367076.nip.io"
SSH_ARGS="-i /opt/cluster/knative-ssh -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"

# exit if CI_JOB is not set
if [ -z ${CI_JOB} ]
then
    echo "Missing CI_JOB variable"
    exit 1
fi

## Fetches the cluster available from the remote power machines
echo "Finding available VM for k8s cluster creation...."
C_NAME=$(ssh ${SSH_ARGS} ${SSH_USER}@${SSH_HOST} ${BASE_DIR}/k8s.sh acquire -v "1.27.4")

if [ -z "$C_NAME" ]; then
    echo "No VMs available now."
    exit 1
else
    if [ "$C_NAME" = "k8s-4109eb" ]; then
        VM_IP="169.54.113.62"
    elif [ "$C_NAME" = "k8s-0ec6f9" ]; then
        VM_IP="169.54.122.204"
    fi
fi

echo "Creating k8s cluster...."
ssh ${SSH_ARGS} ${SSH_USER}@${VM_IP} ${K8S_AUTOMN_DIR}/create-cluster.sh

if [ $? != 0 ]
then
    echo "Cluster creation failed."
    exit 1
fi

echo "Setting up access to k8s cluster...."
# copy access files
scp ${SSH_ARGS} ${SSH_USER}@${VM_IP}:${K8S_AUTOMN_DIR}/share/kubeconfig /tmp
#scp ${SSH_ARGS} ${SSH_USER}@${SSH_HOST}:${K8S_POOL_DIR}/${C_NAME}/kubeconfig /tmp
scp ${SSH_ARGS} ${SSH_USER}@${SSH_HOST}:/root/cluster-pool/pool/k8s/"${C_NAME}"/config.json /tmp

# setup docker access
mkdir -p $HOME/.docker/
cp /tmp/config.json $HOME/.docker/

# setup k8s access
mkdir -p $HOME/.kube/
mv /tmp/kubeconfig $HOME/.kube/config

curl --connect-timeout 10 --retry 5 -sL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml | sed '/.*--metric-resolution.*/a\        - --kubelet-insecure-tls' | kubectl apply -f -

# TODO: merge with patching conditional code below?
if [[ ${CI_JOB} =~ client-* ]]
then
    create_registry_secrets_in_serving &> /dev/null
    install_contour &> /dev/null
elif [[ ${CI_JOB} =~ operator-* ]]
then
    install_contour &> /dev/null
elif [[ ${CI_JOB} =~ contour-* || ${CI_JOB} =~ kourier-* ]]
then
    create_registry_secrets_in_serving &> /dev/null
elif [[ ${CI_JOB} =~ plugin_event-* ]]
then
    create_registry_secrets_in_serving &> /dev/null

fi

echo 'Cluster setup successfully'
echo 'Patching source code with ppc64le specific changes....'
KNATIVE_COMPONENT=$(echo ${CI_JOB} | cut -d '-' -f1)
RELEASE=$(echo ${CI_JOB} | cut -d '-' -f2-)

if [[ ${CI_JOB} =~ contour-* || ${CI_JOB} =~ kourier-* ]]
then
    scp ${SSH_ARGS} ${SSH_USER}@${SSH_HOST}:${BASE_DIR}/adjust/serving/${KNATIVE_COMPONENT}/${RELEASE}/* /tmp/
elif [[ ${CI_JOB} =~ eventing_rekt-* ]]
then
    scp ${SSH_ARGS} ${SSH_USER}@${SSH_HOST}:${BASE_DIR}/adjust/eventing/main/* /tmp/
else
    scp ${SSH_ARGS} ${SSH_USER}@${SSH_HOST}:${BASE_DIR}/adjust/${KNATIVE_COMPONENT}/${RELEASE}/* /tmp/
fi


## Fetch & run adjust.sh script to patch the source code with image replacements and other fixes
## Introducing CI_JOB var which can be used to fetch adjust script based on repo-tag
## $CI_JOB needs to be set in knative upstream job configurations

chmod +x /tmp/adjust.sh
. /tmp/adjust.sh ${C_NAME}