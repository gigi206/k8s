#!/usr/bin/env bash

NAMESPACE="linkerd-viz"

indent_code() {
    local code="$1"
    local indent_size="$2"
    local indent=$(printf '%*s' "$indent_size")
    echo "$code" | sed "s/^/$indent/"
}

# for ID in $(curl -s https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml | egrep gnetId | awk '{ print $NF }' | sort)
# do
#     DASHBOARD="$(curl -s https://grafana.com/api/dashboards/${ID}/revisions/latest/download | sed 's@${DS_PROMETHEUS}@Prometheus@g')"
for DASHBOARD_NAME in $(curl -s "https://api.github.com/repos/linkerd/linkerd2/contents/grafana/dashboards" | jq -r '.[] | .name' | egrep \.json$)
do
    # DASHBOARD="$(curl -s https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/dashboards/${DASHBOARD_NAME} | sed 's@${DS_PROMETHEUS}@Prometheus@g')"
    DASHBOARD="$(curl -s https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/dashboards/${DASHBOARD_NAME})"
    # [ ! $(echo "${DASHBOARD}" | jq -r '.tags' | grep -w "linkerd") ] && echo "Dashboard ${ID} - $(echo "${DASHBOARD}" | jq -r '.title') [SKIP]" && continue
    [ ! $(echo "${DASHBOARD}" | jq -r '.tags' | grep -w "linkerd") ] && echo "Dashboard $(echo "${DASHBOARD}" | jq -r '.title') [SKIP]" && continue
    echo "Dashboard $(echo "${DASHBOARD}" | jq -r '.title')"
    # echo "Dashboard ${ID} - $(echo "${DASHBOARD}" | jq -r '.title')"
    # cat <<EOF | kubectl apply -f -
    cat <<EOF > $(dirname ${0})/install/grafana-dashboard-$(echo "${DASHBOARD}" | jq -r '.uid').yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-$(echo "${DASHBOARD}" | jq -r '.uid')
  namespace: ${NAMESPACE}
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_dashboard_folder: $(kubectl get pod -n prometheus-stack -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="FOLDER")].value}')/linkerd
data:
  $(echo "${DASHBOARD}" | jq -r '.uid').json: |
$(indent_code "${DASHBOARD}" "4")
EOF
done

