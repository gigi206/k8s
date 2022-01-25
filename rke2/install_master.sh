#!/usr/bin/env bash
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export INSTALL_RKE2_VERSION=v1.23.8+rke2r1
# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

curl -sfL https://get.rke2.io | sh -
test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
mkdir -p /etc/rancher/rke2
# echo "RKE2_CNI=calico" >> /usr/local/lib/systemd/system/rke2-server.env
# echo "RKE2_CNI=calico" >> "${CONFIG_PATH}"
# echo "cni: [calico]" > /etc/rancher/rke2/config.yaml
# profile: cis-1.6
echo "disable: [rke2-ingress-nginx]" >> /etc/rancher/rke2/config.yaml
# echo "disable: [rke2-ingress-nginx, rke2-coredns]" >> /etc/rancher/rke2/config.yaml
echo "tls-san: [k8s-api.gigix]" >> /etc/rancher/rke2/config.yaml
# echo "kube-controller-manager-arg: [node-monitor-period=2s, node-monitor-grace-period=16s, pod-eviction-timeout=30s]" >> /etc/rancher/rke2/config.yaml
# echo "node-label: [site=xxx, room=xxx]" >> /etc/rancher/rke2/config.yaml
systemctl enable --now rke2-server.service
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubectl krew
(
  krew_tmp_dir="$(mktemp -d)" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz" &&
  tar zxvf krew-linux_amd64.tar.gz &&
  KREW=./krew-linux_amd64 &&
  "${KREW}" install krew
  rm -fr "${krew_tmp_dir}"
)

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
kubectl krew install ctx
kubectl krew install ns

# Waiting for the kubernetes API before interacting with it
while true
  do
  lsof -Pni:6443 &>/dev/null && break
  echo "Waiting for the kubernetes API..."
  sleep 1
done

# Change ClusterIP to LoadBalancer
kubectl patch svc kubernetes -n default -p '{"spec": {"type": "LoadBalancer"}, "metadata": {"annotations": {"external-dns.alpha.kubernetes.io/hostname": "k8s-api.gigix"}}}'
