#!/usr/bin/env bash

# Please see:
# - https://operatorhub.io/operator/argocd-operator
# - https://argocd-operator.readthedocs.io/en/latest/usage/ha/
# git clone https://github.com/argoproj-labs/argocd-operator
# cd argocd-operator
# make install && make deploy
# Apply the code below and take a look at examples/argocd-ingress.yaml
# apiVersion: argoproj.io/v1alpha1
# kind: ArgoCD
# metadata:
#   name: example-argocd
#   labels:
#     example: ha
# spec:
#   ha:
#     enabled: true

# Install Argocd
#. "$(dirname $0)/../lib.sh"
eval $(cat $(dirname $0)/../lib.sh | egrep -w ^NAMESPACE_ARGOCD)

ARGOCD_CMD_INSTALL="argocd --port-forward --port-forward-namespace ${NAMESPACE_ARGOCD} --insecure"

rm -fr ~/.argocd

echo "Downloading argocd binary..."
# test -x /usr/local/bin/argocd || curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
# chmod +x /usr/local/bin/argocd
which argocd || sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install argocd'
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)

# helm repo add argo-cd https://argoproj.github.io/argo-helm
# helm repo update
# helm install argo-cd argo-cd/argo-cd -n ${NAMESPACE_ARGOCD} --create-namespace
# helm repo remove ${NAMESPACE_ARGOCD}
kubectl create ns ${NAMESPACE_ARGOCD}
helm template argo-cd argo-cd -n ${NAMESPACE_ARGOCD} --repo https://argoproj.github.io/argo-helm | kubectl apply -n ${NAMESPACE_ARGOCD} -f -

. "$(dirname $0)/../lib.sh"
wait_app

sleep 30

PASSWORD="$(kubectl -n ${NAMESPACE_ARGOCD} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "USERNAME: admin"
echo "PASSWORD: ${PASSWORD}"

${ARGOCD_CMD_INSTALL} login --username admin --password "${PASSWORD}"

tty -s && (
    while true; do
        echo -n "New password:"
        read -s NEW_PASSWORD
        ${ARGOCD_CMD_INSTALL} account update-password --current-password "${PASSWORD}" --new-password "${NEW_PASSWORD}" && break || echo "Failed to change the argocd password"
    done
    kubectl -n ${NAMESPACE_ARGOCD} delete secret argocd-initial-admin-secret
)

# require_app cert-manager ingress-nginx
require_app cert-manager ingress-nginx external-dns
# require_app cert-manager ingress-nginx metallb kubevip external-dns
# require_app kubevip kubevip-cloud-provider cert-manager ingress-nginx

# install_app
kubectl apply -f "$(dirname $0)/argocd.yaml"
${ARGOCD_CMD_INSTALL} app sync ${APPNAME}
# wait_app
for RESSOURCE in $(kubectl get -n ${NAMESPACE_ARGOCD} deploy -o name) $(kubectl get -n ${NAMESPACE_ARGOCD} sts -o name) $(kubectl get -n ${NAMESPACE_ARGOCD} daemonset -o name); do
    echo "Waiting ressource ${RESSOURCE}"
    kubectl rollout -n ${NAMESPACE_ARGOCD} status ${RESSOURCE}
done
# show_ressources

# INGRESS_HOST=$(kubectl get ingress argo-cd-argocd-server -n ${NAMESPACE_ARGOCD} -o json | jq -r ".spec.rules[0].host")
# INGRESS_PATH=$(kubectl get ingress argo-cd-argocd-server -n ${NAMESPACE_ARGOCD} -o json | jq -r ".spec.rules[0].http.paths[0].path")
# echo "Please visit http://${INGRESS_HOST}/${INGRESS_PATH}"

# ${ARGOCD_CMD} admin dashboard
# echo "kubectl port-forward service/argo-cd-argocd-server -n ${NAMESPACE_ARGOCD} 8080:443"
# kubectl port-forward service/argo-cd-argocd-server -n ${NAMESPACE_ARGOCD} 8080:443
