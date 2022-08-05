#!/usr/bin/env bash

if [ ! -x /usr/local/bin/argo ]
then
    LAST_RELEASE=$(curl --silent https://api.github.com/repos/vmware-tanzu/velero/releases/latest | jq -r '.tag_name')
    echo "Downloading argo ${LAST_RELEASE}"
    cd /tmp
    curl -L https://github.com/vmware-tanzu/velero/releases/download/${LAST_RELEASE}/velero-${LAST_RELEASE}-linux-amd64.tar.gz | tar xzf -
    mv velero-${LAST_RELEASE}-linux-amd64/velero /usr/local/bin/
    cd -
    rm -fr /tmp/velero-${LAST_RELEASE}-linux-amd64
fi
