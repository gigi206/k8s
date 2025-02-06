#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

# kubectl -n external-dns-system create secret generic etcd-client-certs \
#   --from-file=ca.crt=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
#   --from-file=client.crt=/var/lib/rancher/rke2/server/tls/etcd/client.crt \
#   --from-file=client.key=/var/lib/rancher/rke2/server/tls/etcd/client.key

# require_app powerdns
# PDNS_API="$(kubectl describe cm powerdns -n powerdns-system | egrep ^api-key= | awk -F'=' '{ print $NF }')"
install_app
# wait_app
# show_ressources
