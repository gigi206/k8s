#!/usr/bin/env bash
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
. /vagrant/git/rke2/RKE2_ENV.sh

# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

curl -sfL https://get.rke2.io | sh -
test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
mkdir -p /etc/rancher/rke2
echo "tls-san: [k8s-management.gigix]" >> /etc/rancher/rke2/config.yaml
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

cp /etc/rancher/rke2/rke2.yaml /vagrant/kube-management.config
sed -i "s@127.0.0.1@$(ip a show dev eth0 | egrep -w inet | awk '{ print $2 }' | awk -F'/' '{ print $1 }')@g" /vagrant/kube-management.config
# sed -i "s@127.0.0.1@k8s-management.gigix@g" /vagrant/kube-management.config

/vagrant/git/argocd/argocd/install-management.sh
/vagrant/git/argocd/cert-manager/install-management.sh
/vagrant/git/argocd/rancher/install-management.sh
