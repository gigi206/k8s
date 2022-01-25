#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

#kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/${VERSION}/cert-manager.crds.yaml

install_app
wait_app
# show_ressources
$(dirname $0)/self-signed.sh
