#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

#kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/${VERSION}/cert-manager.crds.yaml

require_app prometheus-stack
install_app
wait_app
# show_ressources
$(dirname $0)/self-signed.sh
Kubectl apply -f $(dirname $0)/prometheus.yaml
