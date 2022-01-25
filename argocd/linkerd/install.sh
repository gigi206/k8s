#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

###

curl https://run.linkerd.io/install | bash
cp -H /root/.linkerd2/bin/linkerd /usr/local/bin/
# rm -fr /root/.linkerd2
linkerd check --pre

####

install_app
wait_app
show_ressources

###

linkerd check

# linkerd viz install | kubectl apply -f -
# linkerd check
# linkerd viz dashboard --address 192.168.122.114
