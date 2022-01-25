#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

"$(dirname $0)/install-requirements.sh"
install_app
wait_app
show_ressources

# ${ARGOCD_CMD} app patch-resource ${APPNAME} --namespace ${NAMESPACE} --kind Service --resource-name longhorn-frontend --patch '{ "metadata": { "annotations": { "external-dns.alpha.kubernetes.io/hostname": "longhorn.gigix" } } }' --patch-type 'application/merge-patch+json'