#!/usr/bin/env bash
. "$(dirname $0)/../lib.sh"

curl https://run.linkerd.io/install | bash
cp -H /root/.linkerd2/bin/linkerd /usr/local/bin/
# rm -fr /root/.linkerd2
# linkerd check --pre

# require_app cert-manager linkerd-cni
kubectl create ns ${NAMESPACE}
kubectl apply -f "$(dirname $0)/install/certificates.yaml"

until [ $(kubectl get certificate -n linkerd linkerd-identity-issuer -o jsonpath="{.status.conditions[0].reason}") = Ready ]
do
    echo "Waiting for certificate..."
    sleep 1
done

CA=$(kubectl get secrets -n ${NAMESPACE} linkerd-identity-issuer -o jsonpath="{.data.ca\.crt}" | base64 -d | sed "s/^/          /g")
CRT=$(kubectl get secrets -n ${NAMESPACE} linkerd-identity-issuer -o jsonpath="{.data.tls\.crt}" | base64 -d | sed "s/^/          /g")
KEY=$(kubectl get secrets -n ${NAMESPACE} linkerd-identity-issuer -o jsonpath="{.data.tls\.key}" | base64 -d | sed "s/^/          /g")

cat <<EOF > "$(dirname $0)/_linkerd.yaml"
# Cf https://linkerd.io/2.11/tasks/install-helm/
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: linkerd
  namespace: argo-cd
spec:
  # Fix bug
  ignoreDifferences:
    - kind: Secret
      name: linkerd-policy-validator-k8s-tls
      # namespace: argo-cd
      # group: apps # kubectl api-resources | grep Deployment | awk '{ print $3 }' | awk -F'/' '{ print $1 }'
      jqPathExpressions:
        - .data.tls.key
        - .data.tls.crt
    - kind: Secret
      name: linkerd-proxy-injector-k8s-tls
      # namespace: argo-cd
      # group: apps # kubectl api-resources | grep Deployment | awk '{ print $3 }' | awk -F'/' '{ print $1 }'
      jqPathExpressions:
        - .data.tls.key
        - .data.tls.crt
    - kind: Secret
      name: linkerd-sp-validator-k8s-tls
      # namespace: argo-cd
      # group: apps # kubectl api-resources | grep Deployment | awk '{ print $3 }' | awk -F'/' '{ print $1 }'
      jqPathExpressions:
        - .data.tls.key
        - .data.tls.crt
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      name: linkerd-proxy-injector-webhook-config
      jqPathExpressions:
        - '.webhooks[0].clientConfig.caBundle'
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      name: linkerd-proxy-injector-webhook-config
      jqPathExpressions:
        - '.webhooks[0].clientConfig.caBundle'
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      name: linkerd-policy-validator-webhook-config
      jqPathExpressions:
        - '.webhooks[0].clientConfig.caBundle'
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      name: linkerd-sp-validator-webhook-config
      jqPathExpressions:
        - '.webhooks[0].clientConfig.caBundle'
    - group: apps
      kind: Deployment
      name: linkerd-destination
      jqPathExpressions:
        - .spec.template.metadata.annotations."checksum/config"
    - group: apps
      kind: Deployment
      name: linkerd-proxy-injector
      jqPathExpressions:
        - .spec.template.metadata.annotations."checksum/config"
    - group: batch
      kind: CronJob
      name: linkerd-heartbeat
      jqPathExpressions:
        - .spec.schedule
  destination:
    namespace: ${NAMESPACE}
    server: 'https://kubernetes.default.svc'
  project: default
  source:
    chart: linkerd2
    repoURL: 'https://helm.linkerd.io/stable'
    targetRevision: 2.11.4
    helm:
      parameters:
      # Cf https://linkerd.io/2.11/tasks/generate-certificates/
      # step certificate create root.linkerd.cluster.local ca.crt ca.key --profile root-ca --no-password --insecure
      - name: identityTrustAnchorsPEM
        value: |
${CA}
      # step certificate create identity.linkerd.cluster.local issuer.crt issuer.key --profile intermediate-ca --not-after 8760h --no-password --insecure --ca ca.crt --ca-key ca.key
      - name: identity.issuer.tls.crtPEM
        value: |
${CRT}
      - name: identity.issuer.tls.keyPEM
        value: |
${KEY}
      # echo \$(date -d '+8760 hour' +"%Y-%m-%dT%H:%M:%SZ")
      # - name: identity.issuer.crtExpiry
      #   value: 2022-11-10T22:35:23Z
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
EOF

####

# install_app
kubectl apply -f "$(dirname $0)/_linkerd.yaml"
rm _linkerd.yaml
sync_app
wait_app
show_ressources

###

linkerd check

# linkerd viz install | kubectl apply -f -
# linkerd check
# linkerd viz dashboard --address 192.168.122.114
