#!/bin/bash

set -e

## --- CONFIGURATION ---
GATEWAY=10.1.199.254
START_IP_SUFFIX=140
BASE_IP="10.1.199"
KUBESPRAY_DIR="kubespray"
INVENTORY_NAME="testk8s"
VM_PREFIX="os"
TEMPLATE_ID=4444
PUB_KEY_FILE="pub_keys"

NODE_LIST=(
  "$BASE_IP.140"
  "$BASE_IP.141"
  "$BASE_IP.142"
  "$BASE_IP.143"
  "$BASE_IP.144"
  "$BASE_IP.145"
  "$BASE_IP.146"
)

### --- Create and initialize the first node ---
echo "Creating first node and initializing SSH..."

./create-vm.sh $TEMPLATE_ID 4140 ${VM_PREFIX}0.cluster.local ${NODE_LIST[0]}/24 $GATEWAY
qm start 4140
sleep 20

# Create SSH key and collect pub key
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${NODE_LIST[0]} "ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa <<<y >/dev/null 2>&1"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${NODE_LIST[0]} "cat ~/.ssh/id_rsa.pub" >> $PUB_KEY_FILE

### --- Create the rest of the nodes ---
echo "Creating other nodes..."

for i in {1..6}; do
  NODE_ID=$((4140 + i))
  IP_SUFFIX=$((START_IP_SUFFIX + i))
  HOSTNAME="${VM_PREFIX}${i}.cluster.local"
  IP="$BASE_IP.$IP_SUFFIX"
  ./create-vm.sh $TEMPLATE_ID $NODE_ID $HOSTNAME $IP/24 $GATEWAY
done

### --- Increase memory for OpenStack nodes ---
qm set 4145 --memory 32768
qm set 4146 --memory 32768

### --- Start all nodes ---
for i in {1..6}; do
  NODE_ID=$((4140 + i))
  qm start $NODE_ID
done

### --- Remote setup on os0 ---
REMOTE_SCRIPT="/home/ubuntu/rook-ceph-deploy.sh"

# Create deployment script locally
cat > /tmp/rook-ceph-deploy.sh <<'EOSCRIPT'
#!/bin/bash

echo "Setting up environment and Rook-Ceph installation on os0..."

set -e

GATEWAY=10.1.199.254
BASE_IP="10.1.199"
KUBESPRAY_DIR="kubespray"
INVENTORY_NAME="testk8s"
VM_PREFIX="os"

# Install kubectl
echo "Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod 755 kubectl && sudo mv kubectl /usr/local/bin

# Prepare Kubespray
echo "Setting up Kubespray..."
sudo apt update && sudo apt install -y git python3-venv python3-pip jq

if [ ! -d "$KUBESPRAY_DIR" ]; then
  git clone https://github.com/kubernetes-sigs/kubespray.git $KUBESPRAY_DIR
fi

cd $KUBESPRAY_DIR
python3 -m venv .venv
source .venv/bin/activate
pip install -U -r requirements.txt --break-system-packages

cp -rfp inventory/sample inventory/$INVENTORY_NAME

# Generate hosts.yaml
# Generate hosts.yaml (os1 = control plane + etcd, os1–os4 = kube nodes)
cat > inventory/$INVENTORY_NAME/hosts.yaml <<EOT
all:
  hosts:
EOT

for i in {1..4}; do
  IP="$BASE_IP.$((140 + i))"
  NAME="${VM_PREFIX}${i}"
  echo "    $NAME:" >> inventory/$INVENTORY_NAME/hosts.yaml
  echo "      ansible_host: $IP" >> inventory/$INVENTORY_NAME/hosts.yaml
  echo "      ip: $IP" >> inventory/$INVENTORY_NAME/hosts.yaml
  echo "      access_ip: $IP" >> inventory/$INVENTORY_NAME/hosts.yaml
done

cat >> inventory/$INVENTORY_NAME/hosts.yaml <<EOT

  children:
    kube_control_plane:
      hosts:
        ${VM_PREFIX}1:

    kube_node:
      hosts:
EOT

for i in {1..4}; do
  echo "        ${VM_PREFIX}${i}:" >> inventory/$INVENTORY_NAME/hosts.yaml
done

cat >> inventory/$INVENTORY_NAME/hosts.yaml <<EOT

    etcd:
      hosts:
        ${VM_PREFIX}1:

    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:

    calico_rr:
      hosts: {}
EOT
# copy kube config to deploy-node
echo "Setting kubeconfig_localhost: true..."
echo "kubeconfig_localhost: true" >> inventory/$INVENTORY_NAME/group_vars/k8s_cluster/k8s-cluster.yml

# Deploy Kubernetes
echo "Deploying Kubernetes cluster with Kubespray..."
ansible-playbook -i inventory/$INVENTORY_NAME/hosts.yaml --become --become-user=root -u ubuntu cluster.yml

# Wait for cluster to be ready
sleep 20

# Clone Rook-Ceph
echo "Installing Rook-Ceph..."
cd ~
# copy kubectl config from remote
mkdir ~/.kube

ssh -o StrictHostKeyChecking=no ubuntu@10.1.199.141 'sudo cat /etc/kubernetes/admin.conf | sed "s/127.0.0.1/10.1.199.141/g"' > ~/.kube/config

## clone and prevent any warning message
git clone https://github.com/rook/rook.git

cd rook/deploy/examples

# Modify cluster.yaml for hostNetwork with tab space added
sed -i '/^  network:/a\    hostNetwork: true' cluster.yaml

# Apply Rook manifests
kubectl apply -f crds.yaml
kubectl apply -f common.yaml
kubectl apply -f operator.yaml

# Wait for operator to be ready
echo "Waiting for Rook operator to start..."
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=180s

# Deploy CephCluster
kubectl apply -f cluster.yaml
# deploy toolbox
kubectl apply -f toolbox.yaml

# enable dashboard for rook-ceph and show the port of it
kubectl apply -f dashboard-external-http.yaml

# grep for the port
## kubectl describe svc -n rook-ceph rook-ceph-mgr-dashboard-external-http|grep Endpoints

# get the admin user password
## echo "Admin password is:"
## kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo

echo -e "\nRook-Ceph installation initiated. Monitor with:"
echo "  kubectl -n rook-ceph get pods -w"
echo "  \nFor remote access, tunnel via ssh -L9999:EndpointsIP:NodePort root@ProxmoxIP"

EOSCRIPT

## run them remotely

# Send script to os0
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/rook-ceph-deploy.sh ubuntu@${NODE_LIST[0]}:$REMOTE_SCRIPT
# Run script remotely
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${NODE_LIST[0]} "chmod +x $REMOTE_SCRIPT && bash $REMOTE_SCRIPT"
