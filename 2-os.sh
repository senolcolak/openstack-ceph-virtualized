#!/bin/bash

set -e

OS0=10.1.199.140
REMOTE_SCRIPT="/home/ubuntu/openstack-deploy.sh"

# Create deployment script locally
cat > /tmp/openstack-deploy.sh <<'EOSCRIPT'
#!/bin/bash
set -e

KOLLA_DIR="kolla"
INVENTORY_NAME="kolla"
BASE_IP="10.1.199"
START_IP_SUFFIX=145
NODE_LIST=("os5:10.1.199.145" "os6:10.1.199.146")

export KUBECONFIG=/home/ubuntu/.kube/config
sudo apt install python3-virtualenv -y
mkdir -p $KOLLA_DIR
cd $KOLLA_DIR
python3 -m venv .venv
source .venv/bin/activate
pip install git+https://opendev.org/openstack/kolla-ansible@master
cp .venv/share/kolla-ansible/ansible/inventory/multinode .
## install deps
kolla-ansible install-deps

sudo mkdir -p /etc/kolla/config /etc/ceph
sudo chown -R $(whoami):$(whoami) /etc/kolla /etc/ceph
cp -r .venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla
 
## generate passwords
kolla-genpwd

# Update inventory
INVENTORY_FILE="multinode"
awk '
  BEGIN {skip=0}
  /^\[.*\]/ {skip=0}
  /^\[control\]/ {print; skip=1; next}
  /^\[compute\]/ {print; skip=1; next}
  /^\[network\]/ {print; skip=1; next}
  /^\[monitoring\]/ {print; skip=1; next}
  /^\[storage\]/ {print; skip=1; next}
  skip==1 && /^[^[]/ {next}
  {print}
' "$INVENTORY_FILE" > "${INVENTORY_FILE}.tmp" && mv "${INVENTORY_FILE}.tmp" "$INVENTORY_FILE"

{
  echo "[control]"
  for node in "${NODE_LIST[@]}"; do
    IFS=":" read -r NAME IP <<< "$node"
    echo "$NAME ansible_host=$IP ansible_user=ubuntu"
  done
  echo
  echo "[compute]"
  for node in "${NODE_LIST[@]}"; do
    IFS=":" read -r NAME IP <<< "$node"
    echo "$NAME ansible_host=$IP ansible_user=ubuntu"
  done
  echo
  echo "[network]"
  for node in "${NODE_LIST[@]}"; do
    IFS=":" read -r NAME IP <<< "$node"
    echo "$NAME ansible_host=$IP ansible_user=ubuntu"
  done
  echo
  echo "[monitoring]"
  for node in "${NODE_LIST[@]}"; do
    IFS=":" read -r NAME IP <<< "$node"
    echo "$NAME ansible_host=$IP ansible_user=ubuntu"
  done
  echo
  echo "[storage]"
  for node in "${NODE_LIST[@]}"; do
    IFS=":" read -r NAME IP <<< "$node"
    echo "$NAME ansible_host=$IP ansible_user=ubuntu"
  done
} >> "$INVENTORY_FILE"

# Generate globals.yml
cat > /etc/kolla/globals.yml <<EOF
---
workaround_ansible_issue_8743: yes
kolla_base_distro: "ubuntu"
kolla_internal_vip_address: "10.1.199.150"
kolla_external_vip_interface: "ens19"
network_interface: "eth0"
neutron_external_interface: "ens19"
neutron_plugin_agent: "openvswitch"
enable_neutron_dvr: "yes"
multiple_regions_names: ["{{ openstack_region_name }}"]
enable_openstack_core: "yes"
enable_hacluster: "yes"
enable_cinder: "yes"
enable_cinder_backup: "yes"
enable_fluentd: "no"
enable_horizon: "yes"
enable_keystone: "yes"
openstack_region_name: "RegionOne"
enable_horizon_neutron_vpnaas: "yes"
enable_masakari: "yes"
enable_masakari_instancemonitor: "yes"
enable_masakari_hostmonitor: "yes"
enable_neutron_vpnaas: "yes"
enable_neutron_provider_networks: "yes"
external_ceph_cephx_enabled: "yes"
ceph_glance_user: "glance"
ceph_glance_pool_name: "images"
ceph_cinder_user: "cinder"
ceph_cinder_keyring: "ceph.client.cinder.keyring"
ceph_cinder_pool_name: "volumes"
cinder_ceph_backends:
  - name: "ceph-rbd"
    cluster: "ceph"
    user: "cinder"
    pool: "volumes"
    type: rbd
    enabled: "{{ cinder_backend_ceph | bool }}"
cinder_backup_ceph_backend:
    name: "ceph-backup-rbd"
    cluster: "ceph"
    user: "cinder-backup"
    pool: "backups"
    type: rbd
    enabled: "{{ enable_cinder_backup | bool }}"
ceph_cinder_backup_user: "cinder-backup"
ceph_cinder_backup_pool_name: "backups"
glance_backend_ceph: "yes"
glance_ceph_backends:
  - name: "ceph-rbd"
    type: "rbd"
    cluster: "ceph"
    pool: "images"
    user: "glance"
    enabled: "{{ glance_backend_ceph | bool }}"
ceph_glance_keyring: "ceph.client.glance.keyring"
ceph_glance_user: "glance"
ceph_glance_pool_name: "images"
ceph_nova_keyring: "ceph.client.nova.keyring"
ceph_nova_user: "nova"
ceph_nova_pool_name: "vms"
cinder_backend_ceph: "yes"
cinder_cluster_name: "testcluster"
cinder_backup_driver: "ceph"
EOF

# Prepare Ceph pools and keyrings
TOOLS_POD=$(kubectl -n rook-ceph get pods -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')
kubectl -n rook-ceph wait --for=condition=Ready pod/$TOOLS_POD --timeout=90s

for pool in volumes images backups vms; do
  echo "Creating Ceph pool: $pool"
  kubectl -n rook-ceph exec -i "$TOOLS_POD" -- bash -c "ceph osd pool ls | grep -q '^$pool$' || ceph osd pool create $pool"
  echo "Initializing Ceph pool: $pool"
  kubectl -n rook-ceph exec -i "$TOOLS_POD" -- bash -c "rbd pool init $pool || true"
done

kubectl -n rook-ceph exec -i "$TOOLS_POD" -- ceph config generate-minimal-conf > /etc/ceph/ceph.conf
echo -e "auth_cluster_required = cephx\nauth_service_required = cephx\nauth_client_required = cephx" >> /etc/ceph/ceph.conf

mkdir -p /etc/kolla/config/cinder/cinder-volume
mkdir -p /etc/kolla/config/cinder/cinder-backup
mkdir -p /etc/kolla/config/glance

kubectl -n rook-ceph exec -i "$TOOLS_POD" -- ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images' \
  mgr 'profile rbd pool=images' \
  > /etc/kolla/config/glance/ceph.client.glance.keyring
cp /etc/ceph/ceph.conf /etc/kolla/config/glance/ceph.conf

kubectl -n rook-ceph exec -i "$TOOLS_POD" -- ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images' \
  mgr 'profile rbd pool=volumes, profile rbd pool=vms' \
  > /etc/kolla/config/cinder/ceph.client.cinder.keyring
cp /etc/ceph/ceph.conf /etc/kolla/config/cinder/ceph.conf

mkdir -p /etc/kolla/config/cinder-backup
kubectl -n rook-ceph exec -i "$TOOLS_POD" -- ceph auth get-or-create client.cinder-backup \
  mon 'profile rbd' \
  osd 'profile rbd pool=backups' \
  mgr 'profile rbd pool=backups' \
  > /etc/kolla/config/cinder-backup/ceph.client.cinder-backup.keyring

cp /etc/ceph/ceph.conf /etc/kolla/config/cinder-backup/ceph.conf
cp /etc/ceph/ceph.conf /etc/ceph/ceph-cinder.conf
echo "keyring = /etc/ceph/ceph.client.cinder.keyring">> /etc/kolla/config/cinder/cinder-volume/ceph.conf
cp /etc/ceph/ceph.conf /etc/ceph/ceph-glance.conf
echo "keyring = /etc/ceph/ceph.client.glance.keyring">> /etc/kolla/config/glance/ceph.conf
cp /etc/kolla/config/cinder/ceph.client.cinder.keyring /etc/kolla/config/cinder/cinder-backup/ceph.client.cinder-backup.keyring

cp /etc/kolla/config/cinder/ceph* /etc/kolla/config/cinder/cinder-volume/
cp /etc/kolla/config/cinder/ceph.client* /etc/kolla/config/cinder/cinder-backup/

cp -rp /etc/kolla/config/cinder /etc/kolla/config/nova

# Clean tabs
find /etc/kolla/config -type f -exec sed -i 's/\t//g' {} +

## nova-compute rbd replacement
echo "[libvirt]" >> /etc/kolla/config/nova/nova-compute.conf
grep "^rbd_secret_uuid" /etc/kolla/passwords.yml |sed 's/:/ =/g' >> /etc/kolla/config/nova/nova-compute.conf

# Kolla deploy
kolla-ansible bootstrap-servers -i multinode
kolla-ansible deploy -i multinode

# Activate NICs for using inside nested VM's
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@10.1.199.145 "sudo ip link set ens19 up"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@10.1.199.146 "sudo ip link set ens19 up"
EOSCRIPT

# Send script to os0
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/openstack-deploy.sh ubuntu@$OS0:$REMOTE_SCRIPT

# Run script remotely
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$OS0 "chmod +x $REMOTE_SCRIPT && bash $REMOTE_SCRIPT"

