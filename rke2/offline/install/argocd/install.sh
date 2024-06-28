#!/usr/bin/env bash

NS="system-argocd"
ARGOCD_CMD="argocd --port-forward --port-forward-namespace ${NS} --insecure"

source charts/env.sh
cd $(dirname $0)
kubectl create ns ${NS}
# helm install --create-namespace --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml
# helm template --namespace ${NS} charts/${CHART}-${VERSION} -f charts/values.yaml | egrep -v "helm.sh/chart|app.kubernetes.io/managed-by: Helm" | kubectl apply -f -
helm template --namespace ${NS} charts/${CHART}-${VERSION} | egrep -v "helm.sh/chart|app.kubernetes.io/managed-by: Helm" | kubectl apply -f -

for RESSOURCE in $(kubectl get -n ${NS} deploy -o name) $(kubectl get -n ${NS} sts -o name) $(kubectl get -n ${NS} daemonset -o name)
do
    echo "Waiting ressource : ${RESSOURCE}"
    kubectl rollout -n ${NS} status ${RESSOURCE}
done

PASSWORD="$(kubectl -n ${NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "USERNAME: admin"
echo "PASSWORD: ${PASSWORD}"

${ARGOCD_CMD} login --username admin --password "${PASSWORD}"

tty -s && (
    while true
    do
        echo -n "New password:"
        read -s NEW_PASSWORD
        ${ARGOCD_CMD} account update-password --current-password "${PASSWORD}" --new-password "${NEW_PASSWORD}" && break || echo "Failed to change the argocd password"
    done
    kubectl -n ${NS} delete secret argocd-initial-admin-secret
)

echo "kubectl port-forward -n ${NS} svc/release-name-argocd-server 8443:443"
