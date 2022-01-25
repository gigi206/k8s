#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

install_app
wait_app
show_ressources

STORAGE_CLASSNAME=$(kubectl apply -f $(dirname $0)/nfs-subdir-external-provisioner.yaml --dry-run=client -o json | jq -r '.spec.source.helm.parameters[] | select(.name == "storageClass.name") | .value')
kubectl patch storageclass ${STORAGE_CLASSNAME} -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
