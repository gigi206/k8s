#!/usr/bin/env bash
. "$(dirname $0)/../lib.sh"

curl https://run.linkerd.io/install | bash
cp -H /root/.linkerd2/bin/linkerd /usr/local/bin/
# rm -fr /root/.linkerd2
# linkerd check --pre

# require_app trust-manager linkerd-cni linkerd-viz
require_app trust-manager
install_app
wait_app

linkerd check

# linkerd viz install | kubectl apply -f -
# linkerd viz dashboard --address 192.168.122.114