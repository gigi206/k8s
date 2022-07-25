#!/usr/bin/env bash

if [ ! -x /usr/local/bin/argo ]
then
    LAST_RELEASE=$(curl --silent https://api.github.com/repos/argoproj/argo-workflows/releases/latest | jq -r '.tag_name')
    echo "Downloading argo ${LAST_RELEASE}"
    curl -L https://github.com/argoproj/argo-workflows/releases/download/${LAST_RELEASE}/argo-linux-amd64.gz | gunzip -c > /usr/local/bin/argo && chmod +x /usr/local/bin/argo
fi
