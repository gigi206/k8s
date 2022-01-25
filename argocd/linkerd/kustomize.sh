#!/usr/bin/bash
# cf https://linkerd.io/2.10/tasks/customize-install/
mkdir -p "$(dirname $0)/kustomize"
linkerd install > "$(dirname $0)/kustomize/linkerd.yaml"
cat << EOF > kustomization.yaml
resources:
- linkerd.yaml
EOF
kubectl kustomize build "$(dirname $0)/kustomize" | kubectl apply -f -
