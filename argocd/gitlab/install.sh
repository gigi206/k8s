#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

require_app longhorn cert-manager
"$(dirname $0)/cert-pki/genCA.sh"
install_app
wait_app
show_ressources
