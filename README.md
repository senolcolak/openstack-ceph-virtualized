
# Proxmox K8s 4-Node Cluster for Rook/Ceph

This repository contains scripts to automate the creation of a 4-node Kubernetes cluster on Proxmox VE. It is specifically designed for running Rook/Ceph as the storage backend and supports multi-bridge network setups (e.g., `vmbr1199` and `vmbr2199`).

---

## 🧩 Features

- Automated VM creation and configuration via Proxmox CLI
- Support for multi-network interfaces (Kolla-Ansible compatibility)
- Prepares nodes for Kubespray-based Kubernetes installation
- Ready for Rook-Ceph deployment
- Generates `globals.yml` and `passwords.yml` for Kolla-Ansible
- Automatically integrates Ceph credentials and configuration
- Supports VM template creation from Ubuntu 24.04 Cloud image

---

## 📦 Requirements

- A working [Proxmox VE](https://www.proxmox.com/en/proxmox-ve) hypervisor
- Internet access on the host machine to download images and tools
- Proxmox CLI access (run as `root`)
- `cloud-init` installed on the guest image
- VM Template ID to clone from

---

## 🚀 Usage

### 1. Clone this repository
```bash
git clone https://github.com/senolcolak/proxmox-k8s4rook.git
cd proxmox-k8s4rook
```

### 2. Create a cloud-init ready VM template (only once)
```bash
./cloud-init-template.sh
```
> ⚙️ This will create a VM template (ID 4444 by default) based on Ubuntu 24.04 Cloud image.

### 3. Deploy 4-node cluster from the template
```bash
./install-k8s.sh <TEMPLATE_ID> <START_VM_ID> <IP_RANGE>
```

Example:
```bash
./install-k8s.sh 4444 5001 10.1.99.121-10.1.99.124
```

> The script will automatically create VMs with:
> - 2 interfaces: `vmbr99` (default) and `vmbr2199`
> - Cloud-init config for each node
> - SSH key injection (you can modify this)
> - Hostname and static IP configuration

---

## 🔐 Ceph / Rook Integration

If you have an existing Rook-Ceph cluster:

- The script will ask for the IP/DNS of the Rook-Ceph toolbox host
- It will fetch `ceph.conf` and relevant keyrings
- These will be placed under `/etc/kolla/config/cinder`, `glance`, `swift`, etc.
- You can modify the behavior in the script to suit your environment

---

## 🛠️ Output Files

- `globals.yml`: Pre-generated for Kolla-Ansible customization
- `passwords.yml`: Auto-generated secure password file
- VM Configurations stored in Proxmox VMDB
- Ceph credentials copied under correct config directories

---

## ⚠️ Notes

- Tested with Ubuntu 24.04 and Proxmox 7.x
- Ensure `vmbr1199` and `vmbr2199` are correctly configured on your Proxmox host
- Make sure cloud-init and SSH keys are functional in the template
- Script assumes 4-node setup, but can be modified easily for more

---

## 📄 License

MIT License

---

## 👤 Author

Created by [Şenol Çolak](https://github.com/senolcolak) – [Kubedo](https://kubedo.io)

---

## 📬 Contributions

Pull requests and suggestions are welcome! Feel free to fork and enhance for your custom use cases.
