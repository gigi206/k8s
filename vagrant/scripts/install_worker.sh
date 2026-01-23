#!/usr/bin/env bash
# https://docs.rke2.io/install/quickstart/#linux-agent-worker-node-installation
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
. /vagrant/scripts/RKE2_ENV.sh
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
mkdir -p /etc/rancher/rke2/

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
echo "Waiting 1st master node to finish his installation"
while true
do
  sleep 5
  test -f /vagrant/k8s-token && break
done
echo "1st master node has finished his installation. This node can continue his installation"
echo "server: https://$(cat /vagrant/ip_master):9345" >> /etc/rancher/rke2/config.yaml
echo "token: $(cat /vagrant/k8s-token)" >> /etc/rancher/rke2/config.yaml
# Add CIS profile if enabled in config.yaml
if [ "$CIS_ENABLED" = "true" ]; then
  echo "profile: ${CIS_PROFILE:-cis}" >> /etc/rancher/rke2/config.yaml
fi
# echo "cni: calico" >> /etc/rancher/rke2/config.yaml
systemctl enable --now rke2-agent.service
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock
