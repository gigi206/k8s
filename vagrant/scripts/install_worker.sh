#!/usr/bin/env bash
# https://docs.rke2.io/install/quickstart/#linux-agent-worker-node-installation
export PATH="${PATH}:/var/lib/rancher/rke2/bin"

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
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
mkdir -p /etc/rancher/rke2/

# Read CIS configuration from vagrant/config/rke2.yaml (structure: rke2.cis.enabled/profile)
CONFIG_FILE="$VAGRANT_DIR/config/rke2.yaml"
CIS_ENABLED=$(grep -A5 "^rke2:" "$CONFIG_FILE" | grep "enabled:" | awk '{print $2}' | tr -d ' ')
CIS_PROFILE=$(grep -A5 "^rke2:" "$CONFIG_FILE" | grep "profile:" | awk '{print $2}' | tr -d '"' | tr -d ' ')

# CIS Hardening: Apply required kernel parameters and create etcd user if enabled
# https://docs.rke2.io/security/hardening_guide
if [ "$CIS_ENABLED" = "true" ]; then
  echo "CIS Hardening enabled with profile: ${CIS_PROFILE:-cis}"

  # Create etcd user/group (required by CIS profile)
  if ! id etcd &>/dev/null; then
    useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
  fi

  # Apply CIS sysctl parameters
  if [ -f /usr/local/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  elif [ -f /usr/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  fi
  systemctl restart systemd-sysctl

  # Read kubelet hardening options from config (with defaults)
  EVENT_QPS=$(grep -A20 "hardening:" "$CONFIG_FILE" | grep "eventQps:" | awk '{print $2}' | tr -d ' ')
  POD_MAX_PIDS=$(grep -A20 "hardening:" "$CONFIG_FILE" | grep "podMaxPids:" | awk '{print $2}' | tr -d ' ')
  ANONYMOUS_AUTH=$(grep -A20 "hardening:" "$CONFIG_FILE" | grep "anonymousAuth:" | awk '{print $2}' | tr -d ' ')
  MAKE_IPTABLES_UTIL_CHAINS=$(grep -A20 "hardening:" "$CONFIG_FILE" | grep "makeIptablesUtilChains:" | awk '{print $2}' | tr -d ' ')
  PROTECT_KERNEL_DEFAULTS=$(grep -A20 "hardening:" "$CONFIG_FILE" | grep "protectKernelDefaults:" | awk '{print $2}' | tr -d ' ')

  # Set defaults if not specified
  EVENT_QPS=${EVENT_QPS:-5}
  POD_MAX_PIDS=${POD_MAX_PIDS:-4096}
  ANONYMOUS_AUTH=${ANONYMOUS_AUTH:-false}
  MAKE_IPTABLES_UTIL_CHAINS=${MAKE_IPTABLES_UTIL_CHAINS:-true}
  PROTECT_KERNEL_DEFAULTS=${PROTECT_KERNEL_DEFAULTS:-true}
fi
echo "Waiting 1st master node to finish his installation"
while true
do
  sleep 5
  test -f $VAGRANT_DIR/k8s-token && break
done
echo "1st master node has finished his installation. This node can continue his installation"
echo "server: https://$(cat $VAGRANT_DIR/ip_master):9345" >> /etc/rancher/rke2/config.yaml
echo "token: $(cat $VAGRANT_DIR/k8s-token)" >> /etc/rancher/rke2/config.yaml
# Add CIS profile if enabled in config.yaml
if [ "$CIS_ENABLED" = "true" ]; then
  echo "profile: ${CIS_PROFILE:-cis}" >> /etc/rancher/rke2/config.yaml

  # Add kubelet args for CIS hardening (K.4.2.1, K.4.2.6, K.4.2.8, K.4.2.11, K.4.2.13)
  echo "kubelet-arg:" >> /etc/rancher/rke2/config.yaml
  echo "- anonymous-auth=$ANONYMOUS_AUTH" >> /etc/rancher/rke2/config.yaml
  echo "- make-iptables-util-chains=$MAKE_IPTABLES_UTIL_CHAINS" >> /etc/rancher/rke2/config.yaml
  echo "- event-qps=$EVENT_QPS" >> /etc/rancher/rke2/config.yaml
  echo "- pod-max-pids=$POD_MAX_PIDS" >> /etc/rancher/rke2/config.yaml
  echo "- protect-kernel-defaults=$PROTECT_KERNEL_DEFAULTS" >> /etc/rancher/rke2/config.yaml
fi
# echo "cni: calico" >> /etc/rancher/rke2/config.yaml
systemctl enable --now rke2-agent.service
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock
