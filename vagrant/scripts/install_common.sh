#!/usr/bin/bash
export DEBIAN_FRONTEND=noninteractive

# Determine script and project directories (agnostic of mount point)
# When run via Vagrant provisioner, BASH_SOURCE may not work correctly
if [ -f "/vagrant/vagrant/scripts/RKE2_ENV.sh" ]; then
  SCRIPT_DIR="/vagrant/vagrant/scripts"
  PROJECT_ROOT="/vagrant"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

apt update
apt full-upgrade -y
apt install -y curl git jq htop cloud-guest-utils

# Install yq (YAML processor by Mike Farah) - used by install_master.sh and install_worker.sh
# NOTE: The apt 'yq' package (kislyuk/yq) is a Python/jq wrapper with incompatible syntax.
# We need mikefarah/yq which supports 'yq eval' and direct 'yq .path file' syntax.
if [ ! -x /usr/local/bin/yq ] || ! /usr/local/bin/yq --version 2>&1 | grep -q "mikefarah"; then
  YQ_VERSION="v4.52.2"
  echo "Installing yq ${YQ_VERSION} (mikefarah)..."
  curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
  echo "yq installed: $(yq --version)"
fi

# Expand root partition to use full disk
echo "Expanding root partition to use full disk..."
ROOT_DEV=$(findmnt -n -o SOURCE /)

if [[ "$ROOT_DEV" == /dev/mapper/* ]]; then
    # LVM setup: expand partition, PV, LV, then filesystem
    echo "Detected LVM root filesystem"
    # Find the physical partition backing LVM (usually vda3)
    PV_DEV=$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' | head -1)
    if [ -n "$PV_DEV" ]; then
        DISK=$(lsblk -no PKNAME "$PV_DEV" | head -1)
        PART_NUM=$(echo "$PV_DEV" | grep -oE '[0-9]+$')
        if [ -n "$DISK" ] && [ -n "$PART_NUM" ]; then
            growpart "/dev/$DISK" "$PART_NUM" 2>/dev/null || true
            pvresize "$PV_DEV" 2>/dev/null || true
            lvextend -l +100%FREE "$ROOT_DEV" 2>/dev/null || true
            resize2fs "$ROOT_DEV" 2>/dev/null || true
        fi
    fi
else
    # Standard partition: just expand partition and filesystem
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV")
    ROOT_PART=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')
    if [ -n "$ROOT_DISK" ] && [ -n "$ROOT_PART" ]; then
        growpart "/dev/$ROOT_DISK" "$ROOT_PART" 2>/dev/null || true
        resize2fs "$ROOT_DEV" 2>/dev/null || true
    fi
fi
echo "Root partition expanded: $(df -h / | tail -1 | awk '{print $2}')"

# Don't install that on the managemnt node
if [ "$1" != "management" ]
then

    # Storage disk setup (/dev/vdb)
    if [ -b /dev/vdb ]; then
        # Read storage provider from ArgoCD config
        STORAGE_PROVIDER=""
        CONFIG_FILE="$PROJECT_ROOT/deploy/argocd/config/config.yaml"
        if [ -f "$CONFIG_FILE" ]; then
            STORAGE_PROVIDER=$(yq '.features.storage.provider' "$CONFIG_FILE")
        fi

        # Only format for Longhorn (Rook needs raw disk)
        if [ "$STORAGE_PROVIDER" = "longhorn" ]; then
            # Requirement for Longhorn (normally for worker, but keep if we use worker + master)
            apt install -y open-iscsi nfs-common util-linux curl bash grep
            systemctl enable --now iscsid.service

            # Check if disk is empty (no filesystem, no partition table)
            if ! blkid /dev/vdb &>/dev/null && ! fdisk -l /dev/vdb 2>/dev/null | grep -q "^/dev/vdb"; then
                echo "Formatting /dev/vdb for Longhorn storage..."
                mkfs.ext4 -F /dev/vdb
                mkdir -p /var/lib/longhorn
                # Add to fstab if not already present
                if ! grep -q "/dev/vdb" /etc/fstab; then
                    echo "/dev/vdb /var/lib/longhorn ext4 defaults 0 2" >> /etc/fstab
                fi
                mount /var/lib/longhorn
                echo "Storage disk /dev/vdb mounted on /var/lib/longhorn"
            else
                echo "Disk /dev/vdb is not empty, skipping format"
            fi
        elif [ "$STORAGE_PROVIDER" = "rook" ]; then
            echo "Storage provider is Rook - keeping /dev/vdb as raw disk"
        else
            echo "Storage provider not detected or unknown ($STORAGE_PROVIDER), skipping disk setup"
        fi
    fi
fi

echo "alias ll='ls -l --color'" >>~/.bashrc
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >>~/.bashrc
echo 'export PATH=/var/lib/rancher/rke2/bin:${KREW_ROOT:-$HOME/.krew}/bin:$PATH' >>~/.bashrc
echo "source <(kubectl completion bash)" >>~/.bashrc
echo "alias k=kubectl" >>~/.bashrc
echo "complete -F __start_kubectl k" >>~/.bashrc
echo "source <(helm completion bash)" >>~/.bashrc
sed -i "/^127.0.1.1/d" /etc/hosts
echo "$(hostname -i) $(hostname)" >>/etc/hosts
sed -i "s/ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/g" /etc/ssh/sshd_config
systemctl restart ssh.service
# localectl set-keymap fr
# localectl set-x11-keymap fr

# Tuning
cat <<EOF >/etc/sysctl.d/k8s.conf
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
EOF
sysctl -p /etc/sysctl.d/k8s.conf

# DNS fix for Cilium host firewall compatibility
# Cilium host firewall blocks UDP loopback traffic to systemd-resolved stub (127.0.0.53)
# Solution: Disable stub listener and use upstream DNS directly
# Ref: https://github.com/cilium/cilium/issues/23838
if systemctl is-active --quiet systemd-resolved; then
    echo "Configuring systemd-resolved for Cilium host firewall compatibility..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat <<EOF >/etc/systemd/resolved.conf.d/no-stub.conf
[Resolve]
DNSStubListener=no
EOF
    # Point resolv.conf to upstream DNS (not stub)
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    echo "DNS configured: using upstream DNS directly (stub listener disabled)"
fi
