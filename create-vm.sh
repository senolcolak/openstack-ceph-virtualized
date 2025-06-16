#!/bin/bash
# usage: program-name template_id vm_id dns_name ip_address gw_address
qm clone $1 $2 --full --name $3
qm set $2 --cores 4
qm set $2 --memory 8192
#qm set $2 --memory 32768
qm set $2 --sshkey pub_keys
qm set $2 --ipconfig0 ip=$4,gw=$5
qm resize $2 scsi0 +25G
#add 2 disks (optional for ceph)
qm set $2 --scsi1 local:100
qm set $2 --scsi2 local:100
#qm start $2
