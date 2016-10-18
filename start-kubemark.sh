#!/bin/bash

# Copyright 2015 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Script that creates a Kubemark cluster with Master running on GCE.

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..

source "${KUBE_ROOT}/test/kubemark/common.sh"

function writeEnvironmentFiles() {
  cat > "${RESOURCE_DIRECTORY}/apiserver_flags" <<EOF
${APISERVER_TEST_ARGS}
--service-cluster-ip-range="${SERVICE_CLUSTER_IP_RANGE}"
EOF
sed -i'' -e "s/\"//g" "${RESOURCE_DIRECTORY}/apiserver_flags"

  cat > "${RESOURCE_DIRECTORY}/scheduler_flags" <<EOF
${SCHEDULER_TEST_ARGS}
EOF
sed -i'' -e "s/\"//g" "${RESOURCE_DIRECTORY}/scheduler_flags"

  cat > "${RESOURCE_DIRECTORY}/controllers_flags" <<EOF
${CONTROLLER_MANAGER_TEST_ARGS}
--allocate-node-cidrs="${ALLOCATE_NODE_CIDRS}"
--cluster-cidr="${CLUSTER_IP_RANGE}"
--service-cluster-ip-range="${SERVICE_CLUSTER_IP_RANGE}"
--terminated-pod-gc-threshold="${TERMINATED_POD_GC_THRESHOLD}"
EOF
sed -i'' -e "s/\"//g" "${RESOURCE_DIRECTORY}/controllers_flags"
}

MAKE_DIR="${KUBE_ROOT}/cluster/images/kubemark"

echo "Copying kubemark to ${MAKE_DIR}"
if [[ -f "${KUBE_ROOT}/_output/release-tars/kubernetes-server-linux-amd64.tar.gz" ]]; then
  # Running from distro
  SERVER_TARBALL="${KUBE_ROOT}/_output/release-tars/kubernetes-server-linux-amd64.tar.gz"
  cp "${KUBE_ROOT}/_output/release-stage/server/linux-amd64/kubernetes/server/bin/kubemark" "${MAKE_DIR}"
elif [[ -f "${KUBE_ROOT}/server/kubernetes-server-linux-amd64.tar.gz" ]]; then
  # Running from an extracted release tarball (kubernetes.tar.gz)
  SERVER_TARBALL="${KUBE_ROOT}/server/kubernetes-server-linux-amd64.tar.gz"
  tar \
    --strip-components=3 \
    -xzf ../../server/kubernetes-server-linux-amd64.tar.gz \
    -C "${MAKE_DIR}" 'kubernetes/server/bin/kubemark' || exit 1
else
  echo 'Cannot find kubernetes/server/bin/kubemark binary'
  exit 1
fi

CURR_DIR=`pwd`
cd "${MAKE_DIR}"
#RETRIES=3
#for attempt in $(seq 1 ${RETRIES}); do
#  if ! make; then
#    if [[ $((attempt)) -eq "${RETRIES}" ]]; then
#      echo "${color_red}Make failed. Exiting.${color_norm}"
#      exit 1
#    fi
#    echo -e "${color_yellow}Make attempt $(($attempt)) failed. Retrying.${color_norm}" >& 2
#    sleep $(($attempt * 5))
#  else
#    break
#  fi
#done
rm kubemark
cd $CURR_DIR



MASTER_IP=##ip of the machine you want to put as kubemark master##
PWSD=##the password of ssh to your master##
KUBECTL=##the path of your kubectl##


  

  ssh ${MASTER_IP} "echo $PWSD | sudo -S docker run --net=host -d gcr.io/google_containers/etcd:2.0.12 /usr/local/bin/etcd \
      --listen-peer-urls http://127.0.0.1:2380 \
      --addr=127.0.0.1:4002 \
      --bind-addr=0.0.0.0:4002 \
      --data-dir=/var/etcd/data"


ensure-temp-dir
gen-kube-bearertoken
create-certs ${MASTER_IP}
KUBELET_TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
KUBE_PROXY_TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)

echo "${CA_CERT_BASE64}" | base64 --decode > "${RESOURCE_DIRECTORY}/ca.crt"
echo "${KUBECFG_CERT_BASE64}" | base64 --decode > "${RESOURCE_DIRECTORY}/kubecfg.crt"
echo "${KUBECFG_KEY_BASE64}" | base64 --decode > "${RESOURCE_DIRECTORY}/kubecfg.key"



password=$(python -c 'import string,random; print("".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16)))')

ssh ${MASTER_IP} \
   "echo $PWSD | sudo -S mkdir /srv/kubernetes -p && \
    sudo bash -c \"echo ${MASTER_CERT_BASE64} | base64 --decode > /srv/kubernetes/server.cert\" && \
    sudo bash -c \"echo ${MASTER_KEY_BASE64} | base64 --decode > /srv/kubernetes/server.key\" && \
    sudo bash -c \"echo ${CA_CERT_BASE64} | base64 --decode > /srv/kubernetes/ca.crt\" && \
    sudo bash -c \"echo ${KUBECFG_CERT_BASE64} | base64 --decode > /srv/kubernetes/kubecfg.crt\" && \
    sudo bash -c \"echo ${KUBECFG_KEY_BASE64} | base64 --decode > /srv/kubernetes/kubecfg.key\" && \
    sudo bash -c \"echo \"${KUBE_BEARER_TOKEN},admin,admin\" > /srv/kubernetes/known_tokens.csv\" && \
    sudo bash -c \"echo \"${KUBELET_TOKEN},kubelet,kubelet\" >> /srv/kubernetes/known_tokens.csv\" && \
    sudo bash -c \"echo \"${KUBE_PROXY_TOKEN},kube_proxy,kube_proxy\" >> /srv/kubernetes/known_tokens.csv\" && \
    sudo bash -c \"echo ${password},admin,admin > /srv/kubernetes/basic_auth.csv\""

writeEnvironmentFiles

scp  \
  "${SERVER_TARBALL}" \
  "${KUBEMARK_DIRECTORY}/start-kubemark-master.sh" \
  "${KUBEMARK_DIRECTORY}/configure-kubectl.sh" \
  "${RESOURCE_DIRECTORY}/apiserver_flags" \
  "${RESOURCE_DIRECTORY}/scheduler_flags" \
  "${RESOURCE_DIRECTORY}/controllers_flags" \
  ${MASTER_IP}:~

ssh ${MASTER_IP} \
  "chmod a+x configure-kubectl.sh && chmod a+x start-kubemark-master.sh && echo $PWSD | sudo -S ./start-kubemark-master.sh ${EVENT_STORE_IP:-127.0.0.1}"

# create kubeconfig for Kubelet:
KUBECONFIG_CONTENTS=$(echo "apiVersion: v1
kind: Config
users:
- name: kubelet
  user:
    client-certificate-data: "${KUBELET_CERT_BASE64}"
    client-key-data: "${KUBELET_KEY_BASE64}"
clusters:
- name: kubemark
  cluster:
    certificate-authority-data: "${CA_CERT_BASE64}"
    server: https://${MASTER_IP}
contexts:
- context:
    cluster: kubemark
    user: kubelet
  name: kubemark-context
current-context: kubemark-context" | base64 | tr -d "\n\r")

KUBECONFIG_SECRET="${RESOURCE_DIRECTORY}/kubeconfig_secret.json"
cat > "${KUBECONFIG_SECRET}" << EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "kubeconfig"
  },
  "type": "Opaque",
  "data": {
    "kubeconfig": "${KUBECONFIG_CONTENTS}"
  }
}
EOF

NODE_CONFIGMAP="${RESOURCE_DIRECTORY}/node_config_map.json"
cat > "${NODE_CONFIGMAP}" << EOF
{
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {
    "name": "node-configmap"
  },
  "data": {
    "content.type": "${TEST_CLUSTER_API_CONTENT_TYPE}"
  }
}
EOF

LOCAL_KUBECONFIG="${RESOURCE_DIRECTORY}/kubeconfig.loc"
cat > "${LOCAL_KUBECONFIG}" << EOF
apiVersion: v1
kind: Config
users:
- name: admin
  user:
    client-certificate-data: "${KUBECFG_CERT_BASE64}"
    client-key-data: "${KUBECFG_KEY_BASE64}"
    username: admin
    password: admin
clusters:
- name: kubemark
  cluster:
    certificate-authority-data: "${CA_CERT_BASE64}"
    server: https://${MASTER_IP}
contexts:
- context:
    cluster: kubemark
    user: admin
  name: kubemark-context
current-context: kubemark-context
EOF

IMAGES=docker.io/wy2745/kubemark

sed "s/##numreplicas##/${NUM_NODES:-10}/g" "${RESOURCE_DIRECTORY}/hollow-node_template.json" > "${RESOURCE_DIRECTORY}/hollow-node.json"
sed -i'' -e "s/\"gcr.io/##project##/kubemark:latest\"/${IMAGES}/g" "${RESOURCE_DIRECTORY}/hollow-node.json"

mkdir "${RESOURCE_DIRECTORY}/addons" || true

sed "s/##MASTER_IP##/${MASTER_IP}/g" "${RESOURCE_DIRECTORY}/heapster_template.json" > "${RESOURCE_DIRECTORY}/addons/heapster.json"
metrics_mem_per_node=4
metrics_mem=$((200 + ${metrics_mem_per_node}*${NUM_NODES:-10}))
sed -i'' -e "s/##METRICS_MEM##/${metrics_mem}/g" "${RESOURCE_DIRECTORY}/addons/heapster.json"
eventer_mem_per_node=500
eventer_mem=$((200 * 1024 + ${eventer_mem_per_node}*${NUM_NODES:-10}))
sed -i'' -e "s/##EVENTER_MEM##/${eventer_mem}/g" "${RESOURCE_DIRECTORY}/addons/heapster.json"

"${KUBECTL}" create -f "${RESOURCE_DIRECTORY}/kubemark-ns.json"
"${KUBECTL}" create -f "${KUBECONFIG_SECRET}" --namespace="kubemark"
"${KUBECTL}" create -f "${NODE_CONFIGMAP}" --namespace="kubemark"
"${KUBECTL}" create -f "${RESOURCE_DIRECTORY}/addons" --namespace="kubemark"
"${KUBECTL}" create -f "${RESOURCE_DIRECTORY}/hollow-node.json" --namespace="kubemark"

#rm "${KUBECONFIG_SECRET}"
#rm "${NODE_CONFIGMAP}"

echo "Waiting for all HollowNodes to become Running..."
start=$(date +%s)
nodes=$("${KUBECTL}" --kubeconfig="${RESOURCE_DIRECTORY}/kubeconfig.loc" get node) || true
ready=$(($(echo "${nodes}" | grep -v "NotReady" | wc -l) - 1))

 until [[ "${ready}" -ge "${NUM_NODES}" ]]; do
   echo -n .
   sleep 1
   now=$(date +%s)
   # Fail it if it already took more than 15 minutes.
   if [ $((now - start)) -gt 900 ]; then
     echo ""
     echo "Timeout waiting for all HollowNodes to become Running"
     # Try listing nodes again - if it fails it means that API server is not responding
     if "${KUBECTL}" --kubeconfig="${RESOURCE_DIRECTORY}/kubeconfig.loc" get node &> /dev/null; then
       echo "Found only ${ready} ready Nodes while waiting for ${NUM_NODES}."
       exit 1
     fi
     echo "Got error while trying to list Nodes. Probably API server is down."
     exit 1
   fi
   nodes=$("${KUBECTL}" --kubeconfig="${RESOURCE_DIRECTORY}/kubeconfig.loc" get node) || true
   ready=$(($(echo "${nodes}" | grep -v "NotReady" | wc -l) - 1))
 done
 echo ""

echo "Password to kubemark master: ${password}"
