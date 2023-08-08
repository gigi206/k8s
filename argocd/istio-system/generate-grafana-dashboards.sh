#!/usr/bin/env bash

NAMESPACE="istio-system"

indent_code() {
    local code="$1"
    local indent_size="$2"
    local indent=$(printf '%*s' "$indent_size")
    echo "$code" | sed "s/^/$indent/"
}

for DASHBOARD_FILE in $(curl -s "https://api.github.com/repos/istio/istio/contents/manifests/addons/dashboards" | jq -r '.[] | .name' | egrep \.json$)
do
    DASHBOARD="$(curl -s https://raw.githubusercontent.com/istio/istio/master/manifests/addons/dashboards/${DASHBOARD_FILE} | sed 's@tags": \[\],@tags": \[\"istio\"\],@g')"
    DASHBOARD_NAME="$(echo ${DASHBOARD_FILE} | awk -F '-dashboard' '{print $1}')"
    echo "Dashboard $(echo "${DASHBOARD}" | jq -r '.title')"
    # cat <<EOF | kubectl apply -f -
    cat <<EOF > $(dirname ${0})/install/grafana-dashboard-${DASHBOARD_NAME}.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-${DASHBOARD_NAME}
  namespace: ${NAMESPACE}
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_dashboard_folder: $(kubectl get pod -n prometheus-stack -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="FOLDER")].value}')/istio
data:
  ${DASHBOARD_NAME}.json: |
$(indent_code "${DASHBOARD}" "4")
EOF
done

