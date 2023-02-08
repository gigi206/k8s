#!/usr/bin/env bash

apt install -y open-iscsi nfs-common util-linux curl bash grep
systemctl enable --now iscsid.service

cat <<EOF | kubectl apply -f -
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: longhorn
driver: driver.longhorn.io
# allowVolumeExpansion: true
deletionPolicy: Delete
EOF

kubectl apply -f "$(dirname $0)/prometheus.yaml"
