#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

require_app linkerd
install_app
wait_app
show_ressources

# ensure the plugin is installed and ready
linkerd check --pre --linkerd-cni-enabled
