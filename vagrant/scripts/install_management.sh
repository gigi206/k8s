#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Determine script and project directories (agnostic of mount point)
# When run via Vagrant provisioner, BASH_SOURCE may not work correctly
if [ -f "/vagrant/vagrant/scripts/RKE2_ENV.sh" ]; then
  SCRIPT_DIR="/vagrant/vagrant/scripts"
  VAGRANT_DIR="/vagrant/vagrant"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  VAGRANT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

. "$SCRIPT_DIR/RKE2_ENV.sh"

# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

curl -sfL https://get.rke2.io | sh -
test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
mkdir -p /etc/rancher/rke2
echo "tls-san: [k8s-management.k8s.lan]" >>/etc/rancher/rke2/config.yaml
systemctl enable --now rke2-server.service
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock

# Brew requirements
apt-get install -y build-essential procps curl file git
curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | sudo -u vagrant bash -
echo 'eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >>~vagrant/.bashrc
sed -i '1i eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' ~/.bashrc

# Helm
# curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install helm'

# kubectl krew
# (
#   krew_tmp_dir="$(mktemp -d)" &&
#     curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz" &&
#     tar zxvf krew-linux_amd64.tar.gz &&
#     KREW=./krew-linux_amd64 &&
#     "${KREW}" install krew
#   rm -fr "${krew_tmp_dir}"
# )
sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install krew'
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
kubectl krew install ctx
kubectl krew install ns

cp /etc/rancher/rke2/rke2.yaml $VAGRANT_DIR/kube-management.config
sed -i "s@127.0.0.1@$(ip a show dev eth0 | egrep -w inet | awk '{ print $2 }' | awk -F'/' '{ print $1 }')@g" $VAGRANT_DIR/kube-management.config
# sed -i "s@127.0.0.1@k8s-management.k8s.lan@g" $VAGRANT_DIR/kube-management.config
