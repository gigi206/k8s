#!/usr/bin/env bash

export VIP=192.168.122.200
export TAG=latest
export INTERFACE=eth1
export CONTAINER_RUNTIME_ENDPOINT=unix:///run/k3s/containerd/containerd.sock
export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
export PATH=/var/lib/rancher/rke2/bin:$PATH
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# curl -s https://kube-vip.io/manifests/rbac.yaml > /var/lib/rancher/rke2/server/manifests/kube-vip-rbac.yaml
curl -s https://kube-vip.io/manifests/rbac.yaml > $(dirname $0)/kube-vip-rbac.yaml
crictl pull docker.io/plndr/kube-vip:$TAG
alias kube-vip="ctr --namespace k8s.io run --rm --net-host docker.io/plndr/kube-vip:${TAG} vip /kube-vip"
kube-vip manifest daemonset \
    --arp \
    --interface $INTERFACE \
    --address $VIP \
    --controlplane \
    --leaderElection \
    --taint \
    --services \
    --inCluster > $(dirname $0)/base/kube-vip.yaml
    #--inCluster | tee /var/lib/rancher/rke2/server/manifests/kube-vip.yaml

# curl -s https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml > /var/lib/rancher/rke2/server/manifests/kube-vip-cloud-controller.yaml
curl -s https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml > $(dirname $0)/overlays/kube-vip-cloud-controller/with-kube-vip-cloud-controller.yaml

