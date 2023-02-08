#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

require_app longhorn cert-manager

# import custom CA
# "$(dirname $0)/cert-pki/genCA.sh"
# Or create a new one with cert-manager
kubectl create ns ${NAMESPACE}
kubectl -n ${NAMESPACE} create secret generic storage-config --from-file="$(dirname $0)/storage-config.ini"
kubectl apply -f "$(dirname $0)/certificate.yaml"
install_app
wait_app
show_ressources
