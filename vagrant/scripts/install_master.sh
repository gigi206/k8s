#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
. /vagrant/scripts/RKE2_ENV.sh
# export INSTALL_RKE2_VERSION=v1.24.8+rke2r1
# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

curl -sfL https://get.rke2.io | sh -
mkdir -p /etc/rancher/rke2

# Read CIS configuration from central config.yaml
CONFIG_FILE="/vagrant/deploy/argocd/config/config.yaml"
CIS_ENABLED=$(grep -A2 "^rke2:" "$CONFIG_FILE" | grep -A1 "cis:" | grep "enabled:" | awk '{print $2}' | tr -d ' ')
CIS_PROFILE=$(grep -A3 "^rke2:" "$CONFIG_FILE" | grep -A2 "cis:" | grep "profile:" | awk '{print $2}' | tr -d '"' | tr -d ' ')

# CIS Hardening: Apply required kernel parameters if enabled
# https://docs.rke2.io/security/hardening_guide
if [ "$CIS_ENABLED" = "true" ]; then
  echo "CIS Hardening enabled with profile: ${CIS_PROFILE:-cis}"
  if [ -f /usr/local/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  elif [ -f /usr/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  fi
  systemctl restart systemd-sysctl
fi
# test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
# echo "RKE2_CNI=calico" >> /usr/local/lib/systemd/system/rke2-server.env
# echo "RKE2_CNI=calico" >> "${CONFIG_PATH}"
# echo "cni: [multus, calico]" > /etc/rancher/rke2/config.yaml
echo "disable:
- rke2-ingress-nginx
- rke2-kube-proxy # Disable kube-proxy with Cilium => https://docs.rke2.io/install/network_options/
- rke2-canal # disable it with cilium
# - rke2-metrics-server
# - rke2-ingress-nginx
# - rke2-coredns
# disable: [rke2-ingress-nginx, rke2-coredns]
disable-kube-proxy: true
# kube-controller-manager-arg:
#   - feature-gates=TopologyAwareHints=true
# cluster-cidr: 10.220.0.0/16
# service-cidr: 10.221.0.0/16
# node-label:
# - xxx=yyy
# system-default-registry: xxx.fr
disable-kube-proxy: true # Disable kube-proxy with Cilium => https://docs.rke2.io/install/network_options/
cni:
- cilium
write-kubeconfig-mode: "0644"
tls-san:
- k8s-api.k8s.lan
- 192.168.121.200
# debug:true
kube-controller-manager-arg:
# - address=0.0.0.0
- bind-address=0.0.0.0
# kube-proxy-arg:
# - address=0.0.0.0
# - metrics-bind-address=0.0.0.0
# kube-apiserver-arg:
#   - feature-gates=TopologyAwareHints=true,JobTrackingWithFinalizers=true
kube-scheduler-arg:
- bind-address=0.0.0.0
etcd-expose-metrics: true
# etcd-snapshot-name: xxx
# etcd-snapshot-schedule-cron: */22****
# etcd-snapshot-retention: 7
# etcd-s3: true
# etcd-s3-bucket: minio
# etcd-s3-region: us-north-9
# etcd-s3-endpoint: minio.k8s.lan
# etcd-s3-access-key: **************************
# etcd-s3-secret-key: **************************" \
>>/etc/rancher/rke2/config.yaml

# Add CIS profile if enabled in config.yaml
if [ "$CIS_ENABLED" = "true" ]; then
  echo "profile: ${CIS_PROFILE:-cis}" >> /etc/rancher/rke2/config.yaml
fi

# echo "kube-controller-manager-arg: [node-monitor-period=2s, node-monitor-grace-period=16s, pod-eviction-timeout=30s]" >> /etc/rancher/rke2/config.yaml
# echo "node-label: [site=xxx, room=xxx]" >> /etc/rancher/rke2/config.yaml

# Configure Cilium CNI
# NOTE: Cilium L2 announcements disabled (known ARP bugs on virtualized interfaces)
# LoadBalancer IP management will be handled by MetalLB (installed via ArgoCD)
/vagrant/scripts/configure_cilium.sh

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

# Krew
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
# https://krew.sigs.k8s.io/plugins/
kubectl krew install ctx           # https://artifacthub.io/packages/krew/krew-index/ctx
kubectl krew install ns            # https://artifacthub.io/packages/krew/krew-index/ns
kubectl krew install access-matrix # https://artifacthub.io/packages/krew/krew-index/access-matrix
kubectl krew install get-all       # https://artifacthub.io/packages/krew/krew-index/get-all
kubectl krew install deprecations  # https://artifacthub.io/packages/krew/krew-index/deprecations
kubectl krew install explore       # https://artifacthub.io/packages/krew/krew-index/explore
kubectl krew install images        # https://artifacthub.io/packages/krew/krew-index/images
kubectl krew install neat          # https://artifacthub.io/packages/krew/krew-index/neat
kubectl krew install pod-inspect   # https://artifacthub.io/packages/krew/krew-index/pod-inspect
kubectl krew install pexec         # https://artifacthub.io/packages/krew/krew-index/pexec
# echo 'source <(kpexec --completion bash)' >>~/.bashrc

# kubectl krew install outdated      # https://artifacthub.io/packages/krew/krew-index/outdated
# kubectl krew install sniff         # https://artifacthub.io/packages/krew/krew-index/sniff
# kubectl krew install ingress-nginx # https://artifacthub.io/packages/krew/krew-index/ingress-nginx
# Waiting for the kubernetes API before interacting with it

# Install which linuxbrew
sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install kustomize cilium-cli hubble k9s'

while true; do
  lsof -Pni:6443 &>/dev/null && break
  echo "Waiting for the kubernetes API..."
  sleep 1
done

# Configure default PriorityClass to avoid preemption
cat <<EOF | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: nonpreempting
value: 0
preemptionPolicy: Never
globalDefault: true
description: "This priority class will not cause other pods to be preempted."
EOF
