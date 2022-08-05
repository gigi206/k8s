#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

install_app
wait_app
# show_ressources

kubectl apply -f "$(dirname $0)/custom.yaml"
