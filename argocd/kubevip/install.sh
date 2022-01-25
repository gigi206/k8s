#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

# kubectl create ns ${NAMESPACE}
# kubectl create configmap --namespace ${NAMESPACE} kubevip --from-literal cidr-global=192.168.122.0/24
# kubectl create configmap --namespace ${NAMESPACE} kubevip --from-literal range-global=192.168.122.201-192.168.122.250

install_app
wait_app
show_ressources
