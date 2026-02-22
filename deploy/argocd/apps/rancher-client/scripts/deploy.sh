#!/usr/bin/env bash
# =============================================================================
# Deploy Rancher Client via Helm (direct deployment, outside ArgoCD)
# =============================================================================
# Usage: ./deploy.sh <rancher-import-url>
#
# Example:
#   ./deploy.sh "https://rancher.192.168.1.100.sslip.io/v3/import/TOKEN_c-CLUSTERID.yaml"
#
# Downloads the Rancher import manifest, extracts connection parameters,
# and deploys the local Helm chart with --set flags.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_YAML="$(cd "${APP_DIR}/../.." && pwd)/config/config.yaml"
IMPORT_URL="${1:?Usage: $0 <rancher-import-url>}"
NAMESPACE="cattle-system"
RELEASE_NAME="rancher-client"

# ---------------------------------------------------------------------------
# Read feature flags from global config.yaml
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_YAML" ]]; then
  echo "[ERROR] Global config not found: $CONFIG_YAML" >&2
  exit 1
fi

CNI_PRIMARY=$(yq '.cni.primary' "$CONFIG_YAML")
EGRESS_ENABLED=$(yq '.features.networkPolicy.egressPolicy.enabled' "$CONFIG_YAML")
KYVERNO_ENABLED=$(yq '.features.kyverno.enabled' "$CONFIG_YAML")
CIS_ENABLED=$(yq '.rke2.cis.enabled' "$CONFIG_YAML")

# Derive Helm feature flags
FEAT_CILIUM_EGRESS=false
if [[ "$CNI_PRIMARY" == "cilium" && "$EGRESS_ENABLED" == "true" ]]; then
  FEAT_CILIUM_EGRESS=true
fi
FEAT_KYVERNO=${KYVERNO_ENABLED:-false}
FEAT_CIS=${CIS_ENABLED:-false}

echo "[INFO] Feature flags (from $CONFIG_YAML):"
echo "  ciliumEgressPolicy:     $FEAT_CILIUM_EGRESS  (cni=$CNI_PRIMARY, egress=$EGRESS_ENABLED)"
echo "  kyvernoPolicyException: $FEAT_KYVERNO"
echo "  cisNamespace:           $FEAT_CIS"

echo "[INFO] Downloading Rancher import manifest..."
MANIFEST=$(curl --insecure -sfL "$IMPORT_URL")

# Extract Rancher server URL from the import URL
SERVER_URL=$(echo "$IMPORT_URL" | sed 's|/v3/import/.*||')
SERVER_IP=$(echo "$SERVER_URL" | sed -E 's|https?://[^.]*\.([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\..*|\1|')
INGRESS_IP_DOMAIN=$(echo "$SERVER_URL" | sed -E 's|https?://[^.]*\.[0-9.]+\.(.*)|\1|')

# Extract values from manifest
CA_CHECKSUM=$(echo "$MANIFEST" | grep -oP 'value:\s*"\K[a-f0-9]{64}' | head -1)
SERVER_VERSION=$(echo "$MANIFEST" | grep -A1 'CATTLE_SERVER_VERSION' | tail -1 | awk '{print $NF}' | tr -d '"')
INSTALL_UUID=$(echo "$MANIFEST" | grep -A1 'CATTLE_INSTALL_UUID' | tail -1 | awk '{print $NF}' | tr -d '"')
CREDENTIAL_NAME=$(echo "$MANIFEST" | grep -A1 'CATTLE_CREDENTIAL_NAME' | tail -1 | awk '{print $NF}' | tr -d '"')
AGENT_IMAGE=$(echo "$MANIFEST" | grep 'image:' | grep rancher | head -1 | awk '{print $2}' | sed 's|:.*||')

# Extract credential secret data
CRED_URL=$(echo "$MANIFEST" | awk '/kind: Secret/{found=1} found && /^\s*url:/{print $2; exit}' | tr -d '"')
CRED_TOKEN=$(echo "$MANIFEST" | awk '/kind: Secret/{found=1} found && /^\s*token:/{print $2; exit}' | tr -d '"')

echo "[INFO] Extracted configuration:"
echo "  Server URL:       $SERVER_URL"
echo "  Server IP:        $SERVER_IP"
echo "  CA Checksum:      $CA_CHECKSUM"
echo "  Server Version:   $SERVER_VERSION"
echo "  Install UUID:     $INSTALL_UUID"
echo "  Credential Name:  $CREDENTIAL_NAME"
echo "  Agent Image:      $AGENT_IMAGE"
echo "  Ingress Domain:   $INGRESS_IP_DOMAIN"

# Pre-create namespaces and Kyverno PolicyExceptions before Helm install.
# Namespaces need PSA labels (CIS) and Helm ownership annotations.
# PolicyExceptions must exist before the Deployment to avoid Kyverno race condition:
# Helm installs CRD resources (PolicyException) after built-in resources (Deployment),
# so Kyverno mutates the Deployment before the exception exists.
HELM_LABELS='app.kubernetes.io/managed-by: Helm'
HELM_ANN_NAME="meta.helm.sh/release-name: $RELEASE_NAME"
HELM_ANN_NS="meta.helm.sh/release-namespace: $NAMESPACE"

# Build PSA labels block (only when CIS is enabled)
PSA_LABELS=""
if [[ "$FEAT_CIS" == "true" ]]; then
  PSA_LABELS="    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted"
fi

echo "[INFO] Pre-creating namespaces..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    $HELM_LABELS
${PSA_LABELS:+$PSA_LABELS}
  annotations:
    $HELM_ANN_NAME
    $HELM_ANN_NS
---
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-fleet-system
  labels:
    $HELM_LABELS
${PSA_LABELS:+$PSA_LABELS}
  annotations:
    $HELM_ANN_NAME
    $HELM_ANN_NS
---
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-impersonation-system
  labels:
    $HELM_LABELS
${PSA_LABELS:+$PSA_LABELS}
  annotations:
    $HELM_ANN_NAME
    $HELM_ANN_NS
---
apiVersion: v1
kind: Namespace
metadata:
  name: cattle-local-user-passwords
  labels:
    $HELM_LABELS
${PSA_LABELS:+$PSA_LABELS}
  annotations:
    $HELM_ANN_NAME
    $HELM_ANN_NS
EOF

if [[ "$FEAT_KYVERNO" == "true" ]]; then
  echo "[INFO] Pre-creating Kyverno PolicyExceptions..."
  kubectl apply -f - <<EOF
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: rancher-client-automount-sa-token
  namespace: $NAMESPACE
  labels:
    $HELM_LABELS
  annotations:
    $HELM_ANN_NAME
    $HELM_ANN_NS
spec:
  exceptions:
    - policyName: disable-automount-sa-token
      ruleNames:
        - disable-automount-sa-token
        - autogen-disable-automount-sa-token
        - autogen-cronjob-disable-automount-sa-token
  match:
    any:
      - resources:
          namespaces:
            - $NAMESPACE
          kinds:
            - Pod
            - Deployment
            - DaemonSet
            - StatefulSet
            - Job
            - CronJob
---
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: rancher-fleet-automount-sa-token
  namespace: cattle-fleet-system
  labels:
    $HELM_LABELS
  annotations:
    $HELM_ANN_NAME
    $HELM_ANN_NS
spec:
  exceptions:
    - policyName: disable-automount-sa-token
      ruleNames:
        - disable-automount-sa-token
        - autogen-disable-automount-sa-token
        - autogen-cronjob-disable-automount-sa-token
  match:
    any:
      - resources:
          namespaces:
            - cattle-fleet-system
          kinds:
            - Pod
            - Deployment
            - DaemonSet
            - StatefulSet
            - Job
            - CronJob
EOF
fi

echo "[INFO] Deploying Helm chart..."
helm upgrade --install "$RELEASE_NAME" "${APP_DIR}/chart" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set server.url="$SERVER_URL" \
  --set server.ip="$SERVER_IP" \
  --set server.caChecksum="$CA_CHECKSUM" \
  --set server.version="$SERVER_VERSION" \
  --set server.installUUID="$INSTALL_UUID" \
  --set server.ingressIpDomain="$INGRESS_IP_DOMAIN" \
  --set credentials.secretName="$CREDENTIAL_NAME" \
  --set credentials.url="$CRED_URL" \
  --set credentials.token="$CRED_TOKEN" \
  --set agent.image="$AGENT_IMAGE" \
  --set features.kyvernoPolicyException="$FEAT_KYVERNO" \
  --set features.ciliumEgressPolicy="$FEAT_CILIUM_EGRESS" \
  --set features.cisNamespace="$FEAT_CIS"

echo "[OK] Rancher client deployed in namespace $NAMESPACE"
