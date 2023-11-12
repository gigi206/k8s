#!/usr/bin/env bash

apt install -y open-iscsi nfs-common util-linux curl bash grep
systemctl enable --now iscsid.service