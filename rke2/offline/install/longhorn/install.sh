#!/usr/bin/env bash

NS="system-longhorn"

source charts/env.sh
cd $(dirname $0)
# Cf https://longhorn.io/docs/1.6.2/deploy/install/#installation-requirements
yum --setopt=tsflags=noscripts install -y iscsi-initiator-utils
echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
systemctl enable iscsid
systemctl start iscsid
dnf install -y nfs-utils util-linux util-linux-core bash curl grep
# Cf https://longhorn.io/docs/1.6.2/deploy/install/#using-the-environment-check-script
./environment_check_${VERSION}.sh
# helm install --create-namespace --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml
helm template --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml | egrep -v "helm.sh/chart|app.kubernetes.io/managed-by: Helm" | kubectl apply -f -

cat <<EOF | kubectl apply -f -
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: longhorn
driver: driver.longhorn.io
deletionPolicy: Delete
EOF
