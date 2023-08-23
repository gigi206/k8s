#!/usr/bin/env bash
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
. /vagrant/git/rke2/RKE2_ENV.sh
# export INSTALL_RKE2_VERSION=v1.24.8+rke2r1
# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

curl -sfL https://get.rke2.io | sh -
test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
mkdir -p /etc/rancher/rke2
# echo "RKE2_CNI=calico" >> /usr/local/lib/systemd/system/rke2-server.env
# echo "RKE2_CNI=calico" >> "${CONFIG_PATH}"
# echo "cni: [multus, calico]" > /etc/rancher/rke2/config.yaml
echo "disable:
# - cni: [multus, canal] # https://docs.rke2.io/install/network_options/#using-multus
- rke2-ingress-nginx
#- rke2-metrics-server
# - rke2-ingress-nginx
# - rke2-coredns
# disable: [rke2-ingress-nginx, rke2-coredns]
# profile: cis-1.23
tls-san:
- k8s-api.gigix
# debug:true
etcd-expose-metrics: true
kube-controller-manager-arg:
# - address=0.0.0.0
- bind-address=0.0.0.0
kube-proxy-arg:
# - address=0.0.0.0
- metrics-bind-address=0.0.0.0
kube-scheduler-arg:
- bind-address=0.0.0.0" \
>> /etc/rancher/rke2/config.yaml


# etcd-snapshot-name: xxx
# etcd-snapshot-schedule-cron: */22****
# etcd-snapshot-retention: 7
# etcd-s3: true
# etcd-s3-bucket: minio
# etcd-s3-region: us-north-9
# etcd-s3-endpoint: minio.gigix
# etcd-s3-access-key: **************************
# etcd-s3-secret-key: **************************


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

while true
  do
  lsof -Pni:6443 &>/dev/null && break
  echo "Waiting for the kubernetes API..."
  sleep 1
done

# Change ClusterIP to LoadBalancer
kubectl patch svc kubernetes -n default -p '{"spec": {"type": "LoadBalancer"}, "metadata": {"annotations": {"external-dns.alpha.kubernetes.io/hostname": "k8s-api.gigix"}}}'

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