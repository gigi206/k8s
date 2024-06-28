#!/usr/bin/env bash

NS="system-cert-manager"

source charts/env.sh
cd $(dirname $0)
# helm install --create-namespace --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml
helm template --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml | egrep -v "helm.sh/chart|app.kubernetes.io/managed-by: Helm" | kubectl apply -f -
