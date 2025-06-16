#!/bin/bash
#wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
qm create 4444 --memory 8192 --net0 virtio,bridge=vmbr1199 --net1 virtio,bridge=vmbr2199 --scsihw virtio-scsi-pci
qm set 4444 --scsi0 local:0,import-from=/root/noble-server-cloudimg-amd64.img
qm set 4444 --ide2 local:cloudinit
qm set 4444 --cpu host
qm set 4444 --boot order=scsi0
qm set 4444 --serial0 socket --vga serial0
qm template 4444
