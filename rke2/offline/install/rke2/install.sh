#!/usr/bin/env bash

RKE2_VERSION=v1.30.1%2Brke2r1
INSTALL_RKE2_ARTIFACT_PATH="$(dirname ${0})/rke2-artifacts"

mkdir "${INSTALL_RKE2_ARTIFACT_PATH}"
cd "${INSTALL_RKE2_ARTIFACT_PATH}"
wget https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2-images.linux-amd64.tar.zst
wget https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2.linux-amd64.tar.gz
wget https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/sha256sum-amd64.txt
curl -sfL https://get.rke2.io --output install.sh
sh install.sh

mkdir -p /etc/rancher/rke2
echo "disable:
- rke2-ingress-nginx
write-kubeconfig-mode: \"0400\"
tls-san:
- $(hostname -i)
# debug:true
etcd-expose-metrics: true" \
>> /etc/rancher/rke2/config.yaml

systemctl enable --now rke2-server.service
