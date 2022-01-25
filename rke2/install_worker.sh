#!/usr/bin/env bash
# https://docs.rke2.io/install/quickstart/#linux-agent-worker-node-installation
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
mkdir -p /etc/rancher/rke2/
echo "Waiting 1st master node to finish his installation"
while true
do
  sleep 5
  test -f /vagrant/k8s-token && break
done
echo "1st master node has finished his installation. This node can continue his installation"
echo "server: https://$(cat /vagrant/ip_master):9345" >> /etc/rancher/rke2/config.yaml
echo "token: $(cat /vagrant/k8s-token)" >> /etc/rancher/rke2/config.yaml
# echo "cni: calico" >> /etc/rancher/rke2/config.yaml
systemctl enable --now rke2-agent.service
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock
