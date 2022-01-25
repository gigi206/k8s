#!/usr/bin/env bash
# exemple
#kubectl patch crd/applications.argoproj.io -p '{"metadata":{"finalizers":[]}}' --type=merge
if [ "$#" -ne 1 ]; then
    echo "$0 get only one argument, example: crd/applications.argoproj.io"
    exit 1
fi
kubectl patch $1 -p '{"metadata":{"finalizers":[]}}' --type=merge
