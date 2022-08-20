#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

"$(dirname $0)/install-requirements.sh"

install_app
wait_app
show_ressources
