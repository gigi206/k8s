#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

ARGOCD_CMD_INSTALL="argocd --port-forward --port-forward-namespace ${NAMESPACE_ARGOCD} --insecure"

PASSWORD="$(kubectl -n ${NAMESPACE_ARGOCD} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "USERNAME: admin"
echo "PASSWORD: ${PASSWORD}"

${ARGOCD_CMD_INSTALL} login --username admin --password "${PASSWORD}"

while true
do
    echo -n "New password:"
    read -s NEW_PASSWORD
    ${ARGOCD_CMD_INSTALL} account update-password --current-password "${PASSWORD}" --new-password "${NEW_PASSWORD}" && break || echo "Failed to change the argocd password"
done

kubectl -n ${NAMESPACE_ARGOCD} delete secret argocd-initial-admin-secret

# require_app metallb cert-manager
require_app prometheus-stack metallb cert-manager ingress-nginx
# install_app
kubectl apply -f "$(dirname $0)/argocd.yaml"
${ARGOCD_CMD_INSTALL} app sync ${APPNAME}
wait_app
show_ressources
