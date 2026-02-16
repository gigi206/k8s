#!/bin/bash
# =============================================================================
# Generate CI config based on detected apps
# =============================================================================
# Reads detection results and generates a config.yaml suitable for CI:
#   - Enables only the apps that need to be tested
#   - Disables resource-heavy components not needed
#   - Sets CI-specific settings (auto-sync, etc.)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/deploy/argocd/config/config.yaml"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }

# =============================================================================
# Get detection results
# =============================================================================

if [ -n "${ALL_APPS:-}" ]; then
  # Already set by caller
  log_info "Using provided ALL_APPS: $ALL_APPS"
else
  # Run detection
  log_info "Running app detection..."
  eval "$("$SCRIPT_DIR/detect-apps.sh" | grep -E '^(INGRESS|EXTRA_APPS|ALL_APPS)=')"
fi

log_info "Generating CI config for apps: $ALL_APPS"

# =============================================================================
# Backup and modify config
# =============================================================================

# Create backup
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

# =============================================================================
# Disable all optional features first
# =============================================================================

log_info "Disabling all optional features..."

# Core features - keep enabled
# metallb, certManager, externalSecrets, externalDns, gatewayAPI - always needed

# Optional features - disable by default
# IMPORTANT: Use empty string "" instead of false because ArgoCD merge generator
# converts all YAML values to strings. Boolean false becomes string "false" which
# is TRUTHY in Go templates. Empty string is correctly FALSY in both Go templates
# and Helm chart conditionals.
yq -i '.features.kubeVip.enabled = ""' "$CONFIG_FILE"
yq -i '.features.serviceMesh.enabled = ""' "$CONFIG_FILE"
yq -i '.features.storage.enabled = ""' "$CONFIG_FILE"
yq -i '.features.databaseOperator.enabled = ""' "$CONFIG_FILE"
yq -i '.features.monitoring.enabled = ""' "$CONFIG_FILE"
yq -i '.features.cilium.monitoring.enabled = ""' "$CONFIG_FILE"
yq -i '.features.logging.enabled = ""' "$CONFIG_FILE"
yq -i '.features.tracing.enabled = ""' "$CONFIG_FILE"
yq -i '.features.sso.enabled = ""' "$CONFIG_FILE"
yq -i '.features.oauth2Proxy.enabled = ""' "$CONFIG_FILE"
yq -i '.features.neuvector.enabled = ""' "$CONFIG_FILE"
yq -i '.features.s3.enabled = ""' "$CONFIG_FILE"
yq -i '.features.registry.enabled = ""' "$CONFIG_FILE"
yq -i '.features.reloader.enabled = ""' "$CONFIG_FILE"
yq -i '.features.cilium.encryption.enabled = ""' "$CONFIG_FILE"
yq -i '.features.cilium.mutualAuth.enabled = ""' "$CONFIG_FILE"
yq -i '.features.cilium.mutualAuth.spire.dataStorage.enabled = ""' "$CONFIG_FILE"
yq -i '.features.kubescape.enabled = ""' "$CONFIG_FILE"
yq -i '.features.ingress.enabled = ""' "$CONFIG_FILE"

# Disable all ingress controllers by default
yq -i '.features.traefik.enabled = ""' "$CONFIG_FILE" 2>/dev/null || true
yq -i '.features.ingressNginx.enabled = ""' "$CONFIG_FILE" 2>/dev/null || true
yq -i '.features.apisix.enabled = ""' "$CONFIG_FILE" 2>/dev/null || true
yq -i '.features.envoyGateway.enabled = ""' "$CONFIG_FILE" 2>/dev/null || true
yq -i '.features.nginxGatewayFabric.enabled = ""' "$CONFIG_FILE" 2>/dev/null || true

# =============================================================================
# Enable features based on detected apps
# =============================================================================

log_info "Enabling features for detected apps..."

for app in $ALL_APPS; do
  case $app in
    # Base apps (always enabled)
    cert-manager|external-dns|external-secrets)
      # Already enabled by default
      ;;
    metallb)
      log_info "  Enabling metallb"
      yq -i '.features.loadBalancer.provider = "metallb"' "$CONFIG_FILE"
      ;;

    # Ingress controllers
    traefik)
      log_info "  Enabling traefik"
      yq -i '.features.gatewayAPI.controller.provider = "traefik"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.gatewayNamespace = "traefik"' "$CONFIG_FILE"
      ;;
    istio)
      log_info "  Enabling istio (service mesh)"
      yq -i '.features.serviceMesh.enabled = true' "$CONFIG_FILE"
      yq -i '.features.serviceMesh.provider = "istio"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.provider = "istio"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.gatewayNamespace = "istio-system"' "$CONFIG_FILE"
      ;;
    istio-gateway)
      # Handled by istio
      ;;
    apisix)
      log_info "  Enabling apisix (with native CRDs)"
      yq -i '.features.gatewayAPI.controller.provider = "apisix"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.gatewayNamespace = "apisix"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.httpRoute.enabled = false' "$CONFIG_FILE"  # Use ApisixRoute instead of HTTPRoute
      ;;
    ingress-nginx)
      log_info "  Enabling ingress-nginx"
      yq -i '.features.gatewayAPI.controller.provider = "nginx"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.gatewayNamespace = "ingress-nginx"' "$CONFIG_FILE"
      ;;
    envoy-gateway)
      log_info "  Enabling envoy-gateway"
      yq -i '.features.gatewayAPI.controller.provider = "envoy-gateway"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.gatewayNamespace = "envoy-gateway-system"' "$CONFIG_FILE"
      ;;
    nginx-gateway-fabric)
      log_info "  Enabling nginx-gateway-fabric"
      yq -i '.features.gatewayAPI.controller.provider = "nginx-gateway-fabric"' "$CONFIG_FILE"
      yq -i '.features.gatewayAPI.controller.gatewayNamespace = "nginx-gateway"' "$CONFIG_FILE"
      ;;

    # SSO group
    keycloak)
      log_info "  Enabling SSO (keycloak)"
      yq -i '.features.sso.enabled = true' "$CONFIG_FILE"
      yq -i '.features.sso.provider = "keycloak"' "$CONFIG_FILE"
      ;;
    oauth2-proxy)
      log_info "  Enabling oauth2-proxy"
      yq -i '.features.oauth2Proxy.enabled = true' "$CONFIG_FILE"
      ;;
    cnpg-operator)
      log_info "  Enabling database operator (cnpg)"
      yq -i '.features.databaseOperator.enabled = true' "$CONFIG_FILE"
      yq -i '.features.databaseOperator.provider = "cnpg"' "$CONFIG_FILE"
      ;;

    # Monitoring group
    prometheus-stack)
      log_info "  Enabling monitoring"
      yq -i '.features.monitoring.enabled = true' "$CONFIG_FILE"
      ;;
    alloy)
      log_info "  Enabling logging (loki + alloy)"
      yq -i '.features.logging.enabled = true' "$CONFIG_FILE"
      yq -i '.features.logging.loki.enabled = true' "$CONFIG_FILE"
      yq -i '.features.logging.loki.collector = "alloy"' "$CONFIG_FILE"
      ;;
    loki)
      log_info "  Enabling logging (loki)"
      yq -i '.features.logging.enabled = true' "$CONFIG_FILE"
      yq -i '.features.logging.loki.enabled = true' "$CONFIG_FILE"
      ;;
    tempo)
      log_info "  Enabling tracing (tempo)"
      yq -i '.features.tracing.enabled = true' "$CONFIG_FILE"
      yq -i '.features.tracing.provider = "tempo"' "$CONFIG_FILE"
      ;;
    jaeger)
      log_info "  Enabling tracing (jaeger)"
      yq -i '.features.tracing.enabled = true' "$CONFIG_FILE"
      yq -i '.features.tracing.provider = "jaeger"' "$CONFIG_FILE"
      ;;

    # Storage group
    longhorn)
      log_info "  Enabling storage (longhorn)"
      yq -i '.features.storage.enabled = true' "$CONFIG_FILE"
      yq -i '.features.storage.provider = "longhorn"' "$CONFIG_FILE"
      yq -i '.features.storage.class = "longhorn"' "$CONFIG_FILE"
      ;;
    rook)
      log_info "  Enabling storage (rook)"
      yq -i '.features.storage.enabled = true' "$CONFIG_FILE"
      yq -i '.features.storage.provider = "rook"' "$CONFIG_FILE"
      yq -i '.features.storage.class = "ceph-block"' "$CONFIG_FILE"
      ;;
    csi-external-snapshotter)
      log_info "  Enabling CSI snapshotter"
      yq -i '.features.storage.csiSnapshotter = true' "$CONFIG_FILE"
      ;;

    # Service mesh extras
    kiali)
      log_info "  Enabling kiali (requires istio)"
      # Istio should already be enabled
      ;;

    # Standalone
    neuvector)
      log_info "  Enabling neuvector"
      yq -i '.features.neuvector.enabled = true' "$CONFIG_FILE"
      ;;
    kube-vip)
      log_info "  Enabling kube-vip"
      yq -i '.features.kubeVip.enabled = true' "$CONFIG_FILE"
      ;;

    *)
      log_info "  Unknown app: $app (skipping)"
      ;;
  esac
done

# =============================================================================
# CI-specific settings
# =============================================================================

log_info "Applying CI-specific settings..."

# Keep environment as dev so merge generator matches per-app config/dev.yaml
# (merge generator joins on the 'environment' key; ci.yaml doesn't exist per-app)
yq -i '.environment = "dev"' "$CONFIG_FILE"

# Enable auto-sync for faster CI
yq -i '.syncPolicy.automated.enabled = true' "$CONFIG_FILE"

# Set cluster distribution for K3d-specific network policies
yq -i '.cluster.distribution = "k3d"' "$CONFIG_FILE"

# Set LoadBalancer provider to metallb (Cilium K3d doesn't have L2 announcements)
yq -i '.features.loadBalancer.provider = "metallb"' "$CONFIG_FILE"

# Configure MetalLB IPs from K3d Docker network (production IPs are not routable)
CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
METALLB_SUBNET=$(docker network inspect "k3d-${CLUSTER_NAME}" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "172.18.0.0/16")
METALLB_BASE=$(echo "$METALLB_SUBNET" | sed 's|\.[0-9]*/.*||')
log_info "K3d Docker network: $METALLB_SUBNET (base: $METALLB_BASE)"

yq -i ".features.loadBalancer.staticIPs.gateway = \"${METALLB_BASE}.200\"" "$CONFIG_FILE"
yq -i ".features.loadBalancer.staticIPs.externalDns = \"${METALLB_BASE}.201\"" "$CONFIG_FILE"
yq -i ".features.loadBalancer.pools.default.range = \"${METALLB_BASE}.210-${METALLB_BASE}.250\"" "$CONFIG_FILE"

# Reduce retry limits for faster failure detection
yq -i '.syncPolicy.retry.limit = 3' "$CONFIG_FILE"
yq -i '.syncPolicy.retry.backoff.maxDuration = "2m"' "$CONFIG_FILE"

# =============================================================================
# Enable Cilium firewall policies (important for proper testing)
# =============================================================================

log_info "Enabling Cilium firewall policies..."

# Enable egress policy (default-deny-external-egress + per-app policies)
yq -i '.features.cilium.egressPolicy.enabled = true' "$CONFIG_FILE"

# Enable host ingress policy (default-deny-host-ingress + per-app policies)
yq -i '.features.cilium.ingressPolicy.enabled = true' "$CONFIG_FILE"

# =============================================================================
# Update git.revision for CI branch
# =============================================================================

if [ -n "${CI_GIT_BRANCH:-}" ]; then
  log_info "Setting git.revision to $CI_GIT_BRANCH..."
  yq -i ".git.revision = \"$CI_GIT_BRANCH\"" "$CONFIG_FILE"
fi

# =============================================================================
# Summary
# =============================================================================

log_success "CI config generated"
log_info "Config file: $CONFIG_FILE"

# Show enabled features
echo ""
echo "=== Enabled Features ==="
yq '.features | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null || true
echo ""
echo "Gateway API Controller: $(yq '.features.gatewayAPI.controller.provider' "$CONFIG_FILE")"
echo "Gateway Namespace: $(yq '.features.gatewayAPI.controller.gatewayNamespace' "$CONFIG_FILE")"
echo ""
echo "=== MetalLB IPs ==="
echo "Gateway IP: $(yq '.features.loadBalancer.staticIPs.gateway' "$CONFIG_FILE")"
echo "External DNS IP: $(yq '.features.loadBalancer.staticIPs.externalDns' "$CONFIG_FILE")"
echo "Default Pool: $(yq '.features.loadBalancer.pools.default.range' "$CONFIG_FILE")"
echo ""
echo "=== Cilium Firewall Policies ==="
echo "Egress Policy: $(yq '.features.cilium.egressPolicy.enabled' "$CONFIG_FILE")"
echo "Host Ingress Policy: $(yq '.features.cilium.ingressPolicy.enabled' "$CONFIG_FILE")"
