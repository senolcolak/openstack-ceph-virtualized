#!/bin/bash

set -e

### this script assumes you have a preconfigured proxmox environment ready ###
# please fill in the following variables
### --- CONFIGURATION ---
## NEEDED - just an empty ID
TEMPLATE_ID=4444
## NEEDED - bridge that internal VM's will be using
BRIDGE1=vmbr1199
## NEEDED - gateway for internal VM's
GATEWAY=10.1.199.254
## NEEDED - below IP+1 suffix will be used
START_IP_SUFFIX=120
## NEEDED - IP subnet only 4 ip's will be used
BASE_IP="10.1.199"
## NEEDED - any prefix
VM_PREFIX="k8snode"

DNS_SUFFIX="local"
## NEEDED - don't forget to put your public keys on the following file
PUB_KEY_FILE="pub_keys"
KUBESPRAY_DIR="kubespray"
INVENTORY_NAME="testk8s"

### --- STEP 1: Create cloud-init template if needed ---
read -p "Create a new Ubuntu cloud-init template first? (y/n): " create_template
if [[ "$create_template" == "y" ]]; then
  echo "Downloading and creating Ubuntu 24.04 cloud image template..."
  wget -N https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img -O /root/noble-server-cloudimg-amd64.img
## 8 GB ram vm deployment
  qm create $TEMPLATE_ID --memory 8192 --net0 virtio,bridge=$BRIDGE1 --scsihw virtio-scsi-pci
  qm set $TEMPLATE_ID --scsi0 local:0,import-from=/root/noble-server-cloudimg-amd64.img
  qm set $TEMPLATE_ID --ide2 local:cloudinit
  qm set $TEMPLATE_ID --cpu host
  qm set $TEMPLATE_ID --boot order=scsi0
  qm set $TEMPLATE_ID --serial0 socket --vga serial0
  qm template $TEMPLATE_ID
fi

### --- STEP 2: Create 4 VMs ---
echo "Creating 4 Kubernetes nodes from template $TEMPLATE_ID..."
HOSTS_YAML_TMP=""
NODE_LIST=()

for i in {1..4}; do
  VM_ID=$((4500 + i))
  IP_SUFFIX=$((START_IP_SUFFIX + i))
  IP="$BASE_IP.$IP_SUFFIX"
  NAME="${VM_PREFIX}${i}"
  NODE_LIST+=("$IP")

  echo "Creating VM $VM_ID ($NAME) with IP $IP..."

  qm clone $TEMPLATE_ID $VM_ID --full --name $NAME
  qm set $VM_ID --cores 4 --memory 8192
  qm set $VM_ID --sshkey $PUB_KEY_FILE
  qm set $VM_ID --ipconfig0 ip=${IP}/24,gw=$GATEWAY
  qm resize $VM_ID scsi0 +25G
  qm set $VM_ID --scsi1 local:100
  qm set $VM_ID --scsi2 local:100
  qm start $VM_ID
done

### --- STEP 3: Install kubectl ---
echo "Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod 755 kubectl && mv kubectl /usr/local/bin

### --- STEP 4: Prepare Kubespray environment ---
echo "Setting up Kubespray..."
apt update && apt install -y git python3-venv python3-pip

if [ ! -d "$KUBESPRAY_DIR" ]; then
  git clone https://github.com/kubernetes-sigs/kubespray.git $KUBESPRAY_DIR
fi

cd $KUBESPRAY_DIR
python3 -m venv .venv
source .venv/bin/activate
pip install -U -r requirements.txt --break-system-packages

cp -rfp inventory/sample inventory/$INVENTORY_NAME

### --- STEP 5: Generate hosts.yaml file ---
echo "Generating hosts.yaml file..."
cat > inventory/$INVENTORY_NAME/hosts.yaml <<EOF
all:
  hosts:
EOF

for i in "${!NODE_LIST[@]}"; do
  IP="${NODE_LIST[$i]}"
  NAME="${VM_PREFIX}${i}"
  cat >> inventory/$INVENTORY_NAME/hosts.yaml <<EOF
    $NAME:
      ansible_host: $IP
      ip: $IP
      access_ip: $IP
EOF
done

cat >> inventory/$INVENTORY_NAME/hosts.yaml <<EOF

  children:
    kube_control_plane:
      hosts:
        ${VM_PREFIX}0:
    kube_node:
      hosts:
EOF

for i in {0..3}; do
  echo "        ${VM_PREFIX}${i}:" >> inventory/$INVENTORY_NAME/hosts.yaml
done

cat >> inventory/$INVENTORY_NAME/hosts.yaml <<EOF

    etcd:
      hosts:
EOF

for i in {0..2}; do
  echo "        ${VM_PREFIX}${i}:" >> inventory/$INVENTORY_NAME/hosts.yaml
done

cat >> inventory/$INVENTORY_NAME/hosts.yaml <<EOF

    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
EOF

### --- Final Notes ---
echo -e "\n✅ Kubernetes cluster VM provisioning complete."
echo "📝 Inventory generated at: $KUBESPRAY_DIR/inventory/$INVENTORY_NAME/hosts.yaml"
echo -e "\n--- NEXT STEPS ---"
echo "You can now customize Kubernetes settings in:"
echo "  inventory/$INVENTORY_NAME/group_vars/k8s_cluster/k8s-cluster.yml"
echo -e "\nWhen ready, run:"
echo "  cd $KUBESPRAY_DIR"
echo "  source .venv/bin/activate"
echo "  ansible-playbook -i inventory/$INVENTORY_NAME/hosts.yaml --become --become-user=root -u ubuntu cluster.yml"
echo -e "\n"
echo "  after kubernetes installation connect to the first node ssh@xxxx"
echo "  clone the rook-ceph repo"
echo "  expose the ports to hostNetwork inside cluster.yaml so you can access from outside"
echo " inside cluster.yaml file -->"
echo "  network:"
echo "     hostNetwork: true"
echo "     connections:"
