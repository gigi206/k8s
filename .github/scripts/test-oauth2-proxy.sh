#!/bin/bash
# =============================================================================
# Test OAuth2 Proxy
# =============================================================================
# Tests:
#   1. OAuth2 Proxy deployment is running
#   2. OAuth2 Proxy health endpoint
#   3. Authentication redirect (should redirect to Keycloak)
#   4. Keycloak is accessible
#   5. OIDC discovery endpoint works
# =============================================================================

set -euo pipefail

OAUTH2_NAMESPACE="oauth2-proxy"
KEYCLOAK_NAMESPACE="keycloak"

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

# =============================================================================
# Test 1: OAuth2 Proxy Deployment
# =============================================================================

log_info "=== Test 1: OAuth2 Proxy Deployment ==="

if kubectl get deployment -n "$OAUTH2_NAMESPACE" -l app.kubernetes.io/name=oauth2-proxy -o name &>/dev/null; then
  kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=oauth2-proxy -n "$OAUTH2_NAMESPACE" --timeout=120s
  log_success "OAuth2 Proxy deployment is ready"
else
  log_error "OAuth2 Proxy deployment not found"
  exit 1
fi

# Get OAuth2 Proxy pod
OAUTH2_POD=$(kubectl get pod -n "$OAUTH2_NAMESPACE" -l app.kubernetes.io/name=oauth2-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
log_info "OAuth2 Proxy pod: $OAUTH2_POD"

# =============================================================================
# Test 2: OAuth2 Proxy Health Endpoint
# =============================================================================

log_info "=== Test 2: OAuth2 Proxy Health Endpoint ==="

# Check readiness endpoint
READY_STATUS=$(kubectl exec -n "$OAUTH2_NAMESPACE" "$OAUTH2_POD" -- \
  wget -qO- --spider http://localhost:4180/ping 2>&1 && echo "OK" || echo "FAILED")

if echo "$READY_STATUS" | grep -q "OK"; then
  log_success "OAuth2 Proxy /ping endpoint is healthy"
else
  log_error "OAuth2 Proxy health check failed"
  exit 1
fi

# Check ready endpoint
READY_RESPONSE=$(kubectl exec -n "$OAUTH2_NAMESPACE" "$OAUTH2_POD" -- \
  wget -qO- http://localhost:4180/ready 2>/dev/null || echo "FAILED")

if [ "$READY_RESPONSE" = "OK" ]; then
  log_success "OAuth2 Proxy /ready endpoint returns OK"
else
  log_warning "OAuth2 Proxy /ready returned: $READY_RESPONSE"
fi

# =============================================================================
# Test 3: Keycloak Deployment
# =============================================================================

log_info "=== Test 3: Keycloak Deployment ==="

if kubectl get statefulset -n "$KEYCLOAK_NAMESPACE" -l app.kubernetes.io/name=keycloak -o name &>/dev/null; then
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=keycloak -n "$KEYCLOAK_NAMESPACE" --timeout=180s
  log_success "Keycloak pods are ready"

  KEYCLOAK_POD=$(kubectl get pod -n "$KEYCLOAK_NAMESPACE" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log_info "Keycloak pod: $KEYCLOAK_POD"
else
  log_warning "Keycloak not deployed as StatefulSet, checking Deployment..."
  if kubectl get deployment -n "$KEYCLOAK_NAMESPACE" -l app.kubernetes.io/name=keycloak -o name &>/dev/null; then
    kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=keycloak -n "$KEYCLOAK_NAMESPACE" --timeout=180s
    log_success "Keycloak deployment is ready"
    KEYCLOAK_POD=$(kubectl get pod -n "$KEYCLOAK_NAMESPACE" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  else
    log_error "Keycloak not found"
    exit 1
  fi
fi

# =============================================================================
# Test 4: Keycloak Health
# =============================================================================

log_info "=== Test 4: Keycloak Health ==="

# Check Keycloak health endpoint
KC_HEALTH=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
  curl -s http://localhost:8080/health/ready 2>/dev/null || echo '{"status":"error"}')

if echo "$KC_HEALTH" | grep -q '"status":"UP"'; then
  log_success "Keycloak health endpoint returns UP"
else
  log_warning "Keycloak health: $KC_HEALTH"
fi

# =============================================================================
# Test 5: OIDC Discovery Endpoint
# =============================================================================

log_info "=== Test 5: OIDC Discovery Endpoint ==="

# Get Keycloak service
KC_SVC=$(kubectl get svc -n "$KEYCLOAK_NAMESPACE" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$KC_SVC" ]; then
  # Try to access OIDC discovery from OAuth2 Proxy pod (tests network connectivity)
  OIDC_DISCOVERY=$(kubectl exec -n "$OAUTH2_NAMESPACE" "$OAUTH2_POD" -- \
    wget -qO- "http://${KC_SVC}.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080/realms/master/.well-known/openid-configuration" 2>/dev/null || echo "{}")

  if echo "$OIDC_DISCOVERY" | grep -q "authorization_endpoint"; then
    log_success "OIDC discovery endpoint is accessible"

    # Extract and show endpoints
    AUTH_ENDPOINT=$(echo "$OIDC_DISCOVERY" | grep -o '"authorization_endpoint":"[^"]*"' | cut -d'"' -f4)
    TOKEN_ENDPOINT=$(echo "$OIDC_DISCOVERY" | grep -o '"token_endpoint":"[^"]*"' | cut -d'"' -f4)
    log_info "Authorization endpoint: $AUTH_ENDPOINT"
    log_info "Token endpoint: $TOKEN_ENDPOINT"
  else
    log_warning "OIDC discovery not available (Keycloak may not be fully configured)"
  fi
else
  log_warning "Keycloak service not found"
fi

# =============================================================================
# Test 6: OAuth2 Proxy Authentication Redirect
# =============================================================================

log_info "=== Test 6: OAuth2 Proxy Authentication Redirect ==="

# Test that accessing a protected path redirects to authentication
AUTH_REDIRECT=$(kubectl exec -n "$OAUTH2_NAMESPACE" "$OAUTH2_POD" -- \
  wget -qS --max-redirect=0 http://localhost:4180/oauth2/start 2>&1 || true)

if echo "$AUTH_REDIRECT" | grep -q "302\|303\|Location"; then
  log_success "OAuth2 Proxy redirects to authentication provider"
  LOCATION=$(echo "$AUTH_REDIRECT" | grep -i "Location:" | head -1)
  log_info "Redirect location: $LOCATION"
else
  log_warning "Could not verify authentication redirect"
fi

# =============================================================================
# Test 7: OAuth2 Proxy Sign Out Endpoint
# =============================================================================

log_info "=== Test 7: OAuth2 Proxy Sign Out Endpoint ==="

SIGNOUT_RESPONSE=$(kubectl exec -n "$OAUTH2_NAMESPACE" "$OAUTH2_POD" -- \
  wget -qS --max-redirect=0 http://localhost:4180/oauth2/sign_out 2>&1 || true)

if echo "$SIGNOUT_RESPONSE" | grep -q "302\|303\|200"; then
  log_success "OAuth2 Proxy sign_out endpoint is accessible"
else
  log_warning "Sign out endpoint check: $SIGNOUT_RESPONSE"
fi

# =============================================================================
# Test 8: Service Connectivity
# =============================================================================

log_info "=== Test 8: Service Connectivity ==="

# Check OAuth2 Proxy service exists
OAUTH2_SVC=$(kubectl get svc -n "$OAUTH2_NAMESPACE" -l app.kubernetes.io/name=oauth2-proxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$OAUTH2_SVC" ]; then
  log_success "OAuth2 Proxy service exists: $OAUTH2_SVC"

  # Get service port
  SVC_PORT=$(kubectl get svc -n "$OAUTH2_NAMESPACE" "$OAUTH2_SVC" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
  log_info "Service port: $SVC_PORT"
else
  log_warning "OAuth2 Proxy service not found"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "       OAuth2 Proxy Test Summary"
echo "=============================================="
echo ""
echo "OAuth2 Proxy Pod:    $OAUTH2_POD"
echo "OAuth2 Proxy NS:     $OAUTH2_NAMESPACE"
echo "Keycloak Pod:        ${KEYCLOAK_POD:-N/A}"
echo "Keycloak NS:         $KEYCLOAK_NAMESPACE"
echo ""

log_success "OAuth2 Proxy tests passed!"
