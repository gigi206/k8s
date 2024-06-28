#!/usr/bin/env bash

NS="system-csi-external-snapshotter-controller"

source charts/env.sh
cd $(dirname $0)

kubectl create ns ${NS}
kubectl create -n ${NS} -k charts/${CHART}-${VERSION}
