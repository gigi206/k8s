#!/usr/bin/env bash

cd $(dirname $0)
cp rke2-ingress-nginx-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml
kubectl apply -f service.yaml
