#!/usr/bin/env bash

cat <<EOF > /etc/sysctl.d/k8s-loft.conf
fs.inotify.max_user_watches=16384
fs.inotify.max_user_instances=256
EOF
sysctl -p /etc/sysctl.d/k8s-loft.conf
