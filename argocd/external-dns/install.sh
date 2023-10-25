#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

# require_app powerdns
# PDNS_API="$(kubectl describe cm powerdns -n powerdns-system | egrep ^api-key= | awk -F'=' '{ print $NF }')"
install_app
wait_app
show_ressources
