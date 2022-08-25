#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

require_app longhorn cert-manager
install_app
wait_app
show_ressources
