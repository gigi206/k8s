#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

"$(dirname $0)/install-requirements.sh"
require_app csi-external-snapshotter prometheus-stack
install_app
wait_app
show_ressources
