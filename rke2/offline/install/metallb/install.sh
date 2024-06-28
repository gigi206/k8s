#!/usr/bin/env bash

NS="system-metallb"

cd $(dirname $0)
source charts/env.sh
# helm install --create-namespace --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml
helm template --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml | egrep -v "helm.sh/chart|app.kubernetes.io/managed-by: Helm" | kubectl apply -f -
kubectl apply -f charts/IPAddressPool.yaml
