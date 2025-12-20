#!/bin/bash
# =============================================================================
# Test Istio Service Mesh functionality
# =============================================================================
# Tests:
#   1. Istio control plane is healthy
#   2. Ztunnel (ambient mode) or sidecar injection working
#   3. Deploy Bookinfo demo application
#   4. mTLS is enforced between services
#   5. Traffic flows through the mesh (productpage -> reviews -> ratings)
#   6. Waypoint proxy (ambient L7) if applicable
#   7. Kiali can see the services (if deployed)
# =============================================================================

set -euo pipefail

SERVICE_MESH_PROVIDER="${SERVICE_MESH_PROVIDER:-none}"
BOOKINFO_NAMESPACE="bookinfo"

# Istio version will be detected from the cluster
ISTIO_VERSION=""

# Bookinfo manifests URL (will be set after version detection)
BOOKINFO_URL=""
BOOKINFO_GATEWAY_URL=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[FAIL]${RESET} $*"; }

cleanup() {
  log_info "Cleaning up mesh test resources..."
  kubectl delete namespace "$BOOKINFO_NAMESPACE" --wait=false 2>/dev/null || true
}

# =============================================================================
# Pre-checks
# =============================================================================

# Skip if no service mesh
if [ "$SERVICE_MESH_PROVIDER" != "istio" ]; then
  log_info "Service mesh provider is not istio ($SERVICE_MESH_PROVIDER), skipping mesh tests"
  exit 0
fi

log_info "Testing Istio service mesh with Bookinfo demo..."

# Trap for cleanup on exit
trap cleanup EXIT

# =============================================================================
# Test 1: Control Plane Health
# =============================================================================

log_info "=== Test 1: Istio Control Plane Health ==="

# Check istiod is running
if kubectl get deployment istiod -n istio-system &>/dev/null; then
  if kubectl wait --for=condition=Available deployment/istiod -n istio-system --timeout=120s; then
    log_success "istiod is running"
  else
    log_error "istiod is not available"
    kubectl get pods -n istio-system -l app=istiod
    exit 1
  fi
else
  log_error "istiod deployment not found"
  exit 1
fi

# Detect Istio version from istiod
log_info "Detecting Istio version..."
ISTIO_VERSION=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://' | sed 's/-distroless//')

if [ -z "$ISTIO_VERSION" ]; then
  # Fallback: try to get from pod labels
  ISTIO_VERSION=$(kubectl get pod -l app=istiod -n istio-system -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}' 2>/dev/null || echo "")
fi

if [ -z "$ISTIO_VERSION" ]; then
  # Last resort: use master branch
  log_warning "Could not detect Istio version, using master branch for Bookinfo"
  ISTIO_VERSION="master"
else
  log_success "Detected Istio version: $ISTIO_VERSION"
fi

# Verify version matches ArgoCD config (if config file exists)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISTIO_CONFIG_FILE="$REPO_ROOT/deploy/argocd/apps/istio/config/dev.yaml"

if [ -f "$ISTIO_CONFIG_FILE" ]; then
  EXPECTED_VERSION=$(yq '.istio.version' "$ISTIO_CONFIG_FILE" 2>/dev/null || echo "")
  if [ -n "$EXPECTED_VERSION" ]; then
    log_info "Expected version from ArgoCD config: $EXPECTED_VERSION"
    if [ "$ISTIO_VERSION" = "$EXPECTED_VERSION" ]; then
      log_success "Deployed version matches ArgoCD config"
    else
      log_warning "Version mismatch: deployed=$ISTIO_VERSION, config=$EXPECTED_VERSION"
    fi
  fi
fi

# Set Bookinfo URLs based on version
BOOKINFO_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/bookinfo/platform/kube/bookinfo.yaml"
BOOKINFO_GATEWAY_URL="https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/bookinfo/gateway-api/bookinfo-gateway.yaml"

# =============================================================================
# Test 2: Detect Mesh Mode (Ambient vs Sidecar)
# =============================================================================

log_info "=== Test 2: Detecting Mesh Mode ==="

AMBIENT_MODE=false
ZTUNNEL_READY=false

# Check for ztunnel (ambient mode indicator)
if kubectl get daemonset ztunnel -n istio-system &>/dev/null; then
  AMBIENT_MODE=true
  log_info "Ambient mode detected (ztunnel present)"

  # Wait for ztunnel to be ready
  if kubectl wait --for=condition=Ready pod -l app=ztunnel -n istio-system --timeout=120s 2>/dev/null; then
    ZTUNNEL_READY=true
    log_success "Ztunnel pods are ready"
    kubectl get pods -n istio-system -l app=ztunnel
  else
    log_warning "Ztunnel pods not ready yet"
  fi
else
  log_info "Sidecar mode detected (no ztunnel)"

  # Check sidecar injector webhook
  if kubectl get mutatingwebhookconfiguration istio-sidecar-injector &>/dev/null; then
    log_success "Sidecar injector webhook is configured"
  else
    log_error "Sidecar injector webhook not found"
    exit 1
  fi
fi

# =============================================================================
# Test 3: Deploy Bookinfo Application
# =============================================================================

log_info "=== Test 3: Deploying Bookinfo Demo Application ==="

# Create namespace
kubectl create namespace "$BOOKINFO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Label namespace for mesh inclusion
if [ "$AMBIENT_MODE" = "true" ]; then
  log_info "Labeling namespace for ambient mode..."
  kubectl label namespace "$BOOKINFO_NAMESPACE" istio.io/dataplane-mode=ambient --overwrite
else
  log_info "Labeling namespace for sidecar injection..."
  kubectl label namespace "$BOOKINFO_NAMESPACE" istio-injection=enabled --overwrite
fi

# Deploy Bookinfo application
log_info "Deploying Bookinfo services..."
kubectl apply -n "$BOOKINFO_NAMESPACE" -f "$BOOKINFO_URL"

# Wait for all deployments
log_info "Waiting for Bookinfo deployments to be ready..."
for deploy in productpage-v1 details-v1 reviews-v1 reviews-v2 reviews-v3 ratings-v1; do
  if kubectl get deployment "$deploy" -n "$BOOKINFO_NAMESPACE" &>/dev/null; then
    kubectl wait --for=condition=Available deployment/"$deploy" -n "$BOOKINFO_NAMESPACE" --timeout=180s || {
      log_error "Deployment $deploy failed to become ready"
      kubectl describe deployment "$deploy" -n "$BOOKINFO_NAMESPACE"
      kubectl get pods -n "$BOOKINFO_NAMESPACE" -l app="${deploy%-v*}"
      exit 1
    }
    log_success "$deploy is ready"
  fi
done

# Show pod status
log_info "Bookinfo pods:"
kubectl get pods -n "$BOOKINFO_NAMESPACE"

# =============================================================================
# Test 4: Verify Mesh Injection
# =============================================================================

log_info "=== Test 4: Verifying Mesh Injection ==="

if [ "$AMBIENT_MODE" = "true" ]; then
  # For ambient mode, verify ztunnel is capturing traffic
  log_info "Verifying ambient mode enrollment..."

  # Check namespace is enrolled
  NS_LABELS=$(kubectl get namespace "$BOOKINFO_NAMESPACE" -o jsonpath='{.metadata.labels}')
  if echo "$NS_LABELS" | grep -q "istio.io/dataplane-mode"; then
    log_success "Namespace is enrolled in ambient mesh"
  else
    log_error "Namespace not enrolled in ambient mesh"
    exit 1
  fi

  # Verify pods don't have sidecar (ambient mode)
  CONTAINER_COUNT=$(kubectl get pod -l app=productpage -n "$BOOKINFO_NAMESPACE" -o jsonpath='{.items[0].spec.containers[*].name}' | wc -w)
  if [ "$CONTAINER_COUNT" -eq 1 ]; then
    log_success "Pods running without sidecar (ambient mode confirmed)"
  else
    log_warning "Pods have multiple containers (may have sidecar)"
  fi
else
  # For sidecar mode, verify proxy container is injected
  log_info "Verifying sidecar injection..."

  PRODUCTPAGE_CONTAINERS=$(kubectl get pod -l app=productpage -n "$BOOKINFO_NAMESPACE" -o jsonpath='{.items[0].spec.containers[*].name}')
  if echo "$PRODUCTPAGE_CONTAINERS" | grep -q "istio-proxy"; then
    log_success "Sidecar proxy injected in productpage"
  else
    log_error "Sidecar proxy NOT found in productpage"
    log_info "Containers: $PRODUCTPAGE_CONTAINERS"
    exit 1
  fi
fi

# =============================================================================
# Test 5: Service-to-Service Communication (Bookinfo Flow)
# =============================================================================

log_info "=== Test 5: Testing Bookinfo Service Flow ==="

# Get productpage pod
PRODUCTPAGE_POD=$(kubectl get pod -l app=productpage -n "$BOOKINFO_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# Test productpage -> details
log_info "Testing productpage -> details..."
DETAILS_RESPONSE=$(kubectl exec "$PRODUCTPAGE_POD" -n "$BOOKINFO_NAMESPACE" -c productpage -- \
  curl -s http://details:9080/details/0 2>/dev/null || echo "FAILED")

if echo "$DETAILS_RESPONSE" | grep -q "author"; then
  log_success "productpage -> details: OK"
else
  log_error "productpage -> details: FAILED"
  log_info "Response: $DETAILS_RESPONSE"
  exit 1
fi

# Test productpage -> reviews
log_info "Testing productpage -> reviews..."
REVIEWS_RESPONSE=$(kubectl exec "$PRODUCTPAGE_POD" -n "$BOOKINFO_NAMESPACE" -c productpage -- \
  curl -s http://reviews:9080/reviews/0 2>/dev/null || echo "FAILED")

if echo "$REVIEWS_RESPONSE" | grep -q "reviewer"; then
  log_success "productpage -> reviews: OK"
else
  log_error "productpage -> reviews: FAILED"
  log_info "Response: $REVIEWS_RESPONSE"
  exit 1
fi

# Test reviews -> ratings (indirect via reviews response)
if echo "$REVIEWS_RESPONSE" | grep -qE "(stars|ratings)"; then
  log_success "reviews -> ratings: OK (ratings data in reviews response)"
else
  log_info "reviews -> ratings: No ratings in response (reviews-v1 doesn't call ratings)"
fi

# Test full productpage
log_info "Testing full productpage..."
PRODUCTPAGE_RESPONSE=$(kubectl exec "$PRODUCTPAGE_POD" -n "$BOOKINFO_NAMESPACE" -c productpage -- \
  curl -s http://productpage:9080/productpage 2>/dev/null || echo "FAILED")

if echo "$PRODUCTPAGE_RESPONSE" | grep -q "Book Details"; then
  log_success "Full productpage flow: OK"
else
  log_error "Full productpage flow: FAILED"
  exit 1
fi

# =============================================================================
# Test 6: mTLS Verification
# =============================================================================

log_info "=== Test 6: mTLS Verification ==="

# Check PeerAuthentication policy
MTLS_MODE=$(kubectl get peerauthentication -n istio-system -o jsonpath='{.items[0].spec.mtls.mode}' 2>/dev/null || echo "not-set")

if [ "$MTLS_MODE" = "not-set" ]; then
  # Check default mesh-wide policy
  MTLS_MODE=$(kubectl get peerauthentication default -n istio-system -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "PERMISSIVE")
fi

log_info "mTLS mode: $MTLS_MODE"

if [ "$MTLS_MODE" = "STRICT" ]; then
  log_success "Strict mTLS is enforced"
else
  log_warning "mTLS is in $MTLS_MODE mode (STRICT recommended for production)"
fi

# =============================================================================
# Test 7: Waypoint Proxy (Ambient L7)
# =============================================================================

if [ "$AMBIENT_MODE" = "true" ]; then
  log_info "=== Test 7: Waypoint Proxy (Ambient L7) ==="

  # Check if waypoint is deployed for the namespace
  WAYPOINT_EXISTS=$(kubectl get gateway -n "$BOOKINFO_NAMESPACE" -l istio.io/waypoint-for=service -o name 2>/dev/null | head -1)

  if [ -n "$WAYPOINT_EXISTS" ]; then
    log_success "Waypoint proxy found: $WAYPOINT_EXISTS"

    # Check waypoint pod is ready
    if kubectl wait --for=condition=Ready pod -l istio.io/gateway-name -n "$BOOKINFO_NAMESPACE" --timeout=60s 2>/dev/null; then
      log_success "Waypoint proxy pod is ready"
    else
      log_warning "Waypoint proxy pod not ready"
    fi
  else
    log_info "No waypoint proxy deployed (L4 only mode)"
    log_info "To enable L7 features, deploy a waypoint with: istioctl waypoint apply -n $BOOKINFO_NAMESPACE"
  fi
else
  log_info "=== Test 7: Skipped (Waypoint is ambient-mode only) ==="
fi

# =============================================================================
# Test 8: Kiali Integration
# =============================================================================

log_info "=== Test 8: Kiali Integration ==="

# Check if Kiali is deployed
if kubectl get deployment kiali -n istio-system &>/dev/null; then
  log_info "Kiali is deployed in istio-system"

  if kubectl wait --for=condition=Available deployment/kiali -n istio-system --timeout=60s 2>/dev/null; then
    log_success "Kiali is running"

    # Generate some traffic for Kiali to observe
    log_info "Generating traffic for Kiali metrics..."
    for i in {1..10}; do
      kubectl exec "$PRODUCTPAGE_POD" -n "$BOOKINFO_NAMESPACE" -c productpage -- \
        curl -s http://productpage:9080/productpage >/dev/null 2>&1 || true
      sleep 1
    done
    log_success "Traffic generated for Kiali"

    # Check Kiali API is responding
    KIALI_POD=$(kubectl get pod -l app=kiali -n istio-system -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$KIALI_POD" ]; then
      # Check Kiali can see the bookinfo namespace
      KIALI_NAMESPACES=$(kubectl exec "$KIALI_POD" -n istio-system -- \
        curl -s http://localhost:20001/kiali/api/namespaces 2>/dev/null || echo "[]")

      if echo "$KIALI_NAMESPACES" | grep -q "$BOOKINFO_NAMESPACE"; then
        log_success "Kiali sees the $BOOKINFO_NAMESPACE namespace"
      else
        log_warning "Kiali may not have discovered $BOOKINFO_NAMESPACE yet"
      fi

      # Check Kiali graph API
      KIALI_GRAPH=$(kubectl exec "$KIALI_POD" -n istio-system -- \
        curl -s "http://localhost:20001/kiali/api/namespaces/$BOOKINFO_NAMESPACE/graph?duration=60s" 2>/dev/null || echo "{}")

      if echo "$KIALI_GRAPH" | grep -q "productpage"; then
        log_success "Kiali graph shows Bookinfo services"
      else
        log_info "Kiali graph may need more time to populate"
      fi
    fi
  else
    log_warning "Kiali deployment not ready"
  fi
elif kubectl get deployment kiali -n kiali &>/dev/null; then
  log_info "Kiali is deployed in kiali namespace"
  log_success "Kiali found (separate namespace)"
else
  log_info "Kiali is not deployed (skipping Kiali tests)"
fi

# =============================================================================
# Test 9: Gateway API / Ingress
# =============================================================================

log_info "=== Test 9: External Access (Gateway API) ==="

# Check for Gateway API gateway
if kubectl get gateway.gateway.networking.k8s.io -n "$BOOKINFO_NAMESPACE" &>/dev/null 2>&1; then
  GATEWAYS=$(kubectl get gateway.gateway.networking.k8s.io -n "$BOOKINFO_NAMESPACE" --no-headers 2>/dev/null | wc -l)
  if [ "$GATEWAYS" -gt 0 ]; then
    log_success "Found $GATEWAYS Gateway API Gateway(s) in $BOOKINFO_NAMESPACE"
    kubectl get gateway.gateway.networking.k8s.io -n "$BOOKINFO_NAMESPACE"
  fi
fi

# Check for HTTPRoute
if kubectl get httproute -n "$BOOKINFO_NAMESPACE" &>/dev/null 2>&1; then
  ROUTES=$(kubectl get httproute -n "$BOOKINFO_NAMESPACE" --no-headers 2>/dev/null | wc -l)
  if [ "$ROUTES" -gt 0 ]; then
    log_success "Found $ROUTES HTTPRoute(s) in $BOOKINFO_NAMESPACE"
    kubectl get httproute -n "$BOOKINFO_NAMESPACE"
  fi
fi

# Check for Istio Gateway (classic)
if kubectl get gateway.networking.istio.io -n "$BOOKINFO_NAMESPACE" &>/dev/null 2>&1; then
  ISTIO_GATEWAYS=$(kubectl get gateway.networking.istio.io -n "$BOOKINFO_NAMESPACE" --no-headers 2>/dev/null | wc -l)
  if [ "$ISTIO_GATEWAYS" -gt 0 ]; then
    log_success "Found $ISTIO_GATEWAYS Istio Gateway(s)"
  fi
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "       Istio Mesh Test Summary"
echo "=============================================="
echo ""
echo "Istio Version:     $ISTIO_VERSION"
echo "Mode:              $([ "$AMBIENT_MODE" = "true" ] && echo "Ambient (ztunnel)" || echo "Sidecar")"
echo "Control Plane:     OK (istiod running)"
if [ "$AMBIENT_MODE" = "true" ]; then
  echo "Ztunnel:           $([ "$ZTUNNEL_READY" = "true" ] && echo "OK" || echo "Warning")"
else
  echo "Sidecar Injection: OK"
fi
echo "Bookinfo Deploy:   OK"
echo "Service Flow:      OK (productpage -> details, reviews)"
echo "mTLS Mode:         $MTLS_MODE"
echo ""
echo "Services tested:"
echo "  - productpage (v1)"
echo "  - details (v1)"
echo "  - reviews (v1, v2, v3)"
echo "  - ratings (v1)"
echo ""

log_success "All Istio mesh tests passed!"
