#!/usr/bin/env bash

NS="system-local-path-storage"

source charts/env.sh
cd $(dirname $0)
mkdir /opt/local-path-provisioner
chmod 777 /opt/local-path-provisioner
# helm install --create-namespace --namespace ${NS} local-path-storage ./git/local-path-provisioner/deploy/chart/local-path-provisioner -f charts/values.yaml
helm template --namespace ${NS} ${CHART} ./git/local-path-provisioner/deploy/chart/${CHART} -f charts/values.yaml | egrep -v "app.kubernetes.io/managed-by: Helm|helm.sh/chart" | kubectl apply -f -
