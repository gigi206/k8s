#!/usr/bin/bash
# Cf https://linkerd.io/2.14/tasks/customize-install/
mkdir -p "$(dirname $0)/kustomize"
linkerd viz install > "$(dirname $0)/kustomize/linkerd-viz.yaml"
cat << EOF > kustomization.yaml
resources:
- linkerd-viz.yaml
- ingress.yaml
EOF
kubectl kustomize build "$(dirname $0)/kustomize" | kubectl apply -f -
