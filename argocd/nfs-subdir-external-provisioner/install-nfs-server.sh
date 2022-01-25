#!/usr/bin/env bash
NFS_PATH=$(kubectl apply -f $(dirname $0)/nfs-subdir-external-provisioner.yaml --dry-run=client -o json | jq -r '.spec.source.helm.parameters[] | select(.name == "nfs.path") | .value')
# POD_CIDR=$(kubectl get node -o json | jq -r ".items[] | select(.metadata.name == \"$(hostname)\") | .spec.podCIDR")
POD_CIDR="192.168.122.0/24"

apt-get update
apt-get install nfs-kernel-server

echo "${NFS_PATH}       ${POD_CIDR}(rw,sync,no_subtree_check)" >> /etc/exports
mkdir "${NFS_PATH}"
chmod 1777 "${NFS_PATH}"

systemctl reload nfs-server.service
