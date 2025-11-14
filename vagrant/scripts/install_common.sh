#!/usr/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt update
apt full-upgrade -y
apt install -y curl git jq htop

# Don't install that on the managemnt node
if [ "$1" != "management" ]
then
    # Requirement for Longhorn (normally for worker, but keep if we use worker + master)
    apt install -y open-iscsi nfs-common util-linux curl bash grep
    systemctl enable --now iscsid.service
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
