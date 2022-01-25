#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

$(dirname $0)/tuning.sh

install_app
wait_app
show_ressources
