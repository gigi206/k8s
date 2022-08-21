#!/usr/bin/env bash
containers=$(/var/lib/rancher/rke2/bin/crictl ps -o json | jq -r '.[][].labels|."io.kubernetes.pod.namespace" + " " + ."io.kubernetes.pod.name" + " " + ."io.kubernetes.container.name"')
echo "${containers}" | while read line
do
    read -r pod_namespace pod_name container_name <<< "${line}"
    kubectl get pod -n "${pod_namespace}" "${pod_name}" &> /dev/null || echo "container from pod ${pod_name} with ns ${pod_namespace} is still running (container: ${container_name})"
done
