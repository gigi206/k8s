#!/usr/bin/env bash
# Cf https://longhorn.io/docs/1.6.2/deploy/install/airgap/#using-a-manifest-file
EXCLUDE_IMAGES="openshift"
cd $(dirname $0)
source charts/env.sh
curl -s https://raw.githubusercontent.com/longhorn/longhorn/${VERSION}/deploy/longhorn-images.txt | while read line
do
    grep "${line}" mapping && continue
    echo "$(echo ${line} | sed 's@:@_@g' | awk -F'/' '{ print $NF }') ${line}" | egrep -v "$EXCLUDE_IMAGES"
done | sort -u >> mapping

