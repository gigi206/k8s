#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

# install_app
kubectl apply -f "$(dirname $0)/cert-manager-management.yaml"
wait_app
# show_ressources
$(dirname $0)/self-signed.sh
