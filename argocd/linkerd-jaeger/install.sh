#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

# Ensure the plugin is installed and ready
linkerd check --pre --linkerd-cni-enabled --linkerd-namespace linkerd-cni

install_app
wait_app
show_ressources
