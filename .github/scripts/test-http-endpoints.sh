#!/bin/bash
# =============================================================================
# Test HTTP endpoints return successful status codes
# =============================================================================
# Tests all configured HTTPRoutes/Ingresses for HTTP 2xx/3xx/401/403 responses
# (401/403 are acceptable as they indicate the service is responding)
# =============================================================================

set -euo pipefail

DOMAIN="${DOMAIN:-k8s.lan}"
TIMEOUT="${HTTP_TIMEOUT:-10}"

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
# Find Gateway/LoadBalancer IP
# =============================================================================

log_info "Testing HTTP endpoints"

GATEWAY_IP=""

# Try Istio Gateway first
GATEWAY_IP=$(kubectl get svc -A -l istio=ingressgateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

# Try other gateways
if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$(kubectl get svc -A -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$(kubectl get svc -A -l app.kubernetes.io/name=nginx-gateway-fabric -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$(kubectl get svc -A -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$(kubectl get svc -A -l app.kubernetes.io/name=envoy-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

if [ -z "$GATEWAY_IP" ]; then
  GATEWAY_IP=$(kubectl get svc -A -l app.kubernetes.io/name=apisix-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

# Fallback to localhost (K3d port mapping)
if [ -z "$GATEWAY_IP" ]; then
  log_warning "No gateway LoadBalancer IP found, using localhost (K3d port mapping)"
  GATEWAY_IP="127.0.0.1"
fi

log_info "Using gateway IP: $GATEWAY_IP"

# =============================================================================
# Get hostnames from all routing resources
# =============================================================================
# Supports: Ingress, HTTPRoute/GRPCRoute/TLSRoute (Gateway API),
#           ApisixRoute (APISIX), VirtualService (Istio), IngressRoute (Traefik)

HOSTNAMES=""

# 1. Kubernetes Ingress (standard)
INGRESS_HOSTS=$(kubectl get ingress -A -o json 2>/dev/null | jq -r '.items[].spec.rules[]?.host // empty' | sort -u | grep -v '^$' || true)
[ -n "$INGRESS_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${INGRESS_HOSTS}\n"

# 2. Gateway API HTTPRoute
HTTPROUTE_HOSTS=$(kubectl get httproute -A -o json 2>/dev/null | jq -r '.items[].spec.hostnames[]? // empty' | sort -u | grep -v '^$' || true)
[ -n "$HTTPROUTE_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${HTTPROUTE_HOSTS}\n"

# 3. Gateway API GRPCRoute
GRPCROUTE_HOSTS=$(kubectl get grpcroute -A -o json 2>/dev/null | jq -r '.items[].spec.hostnames[]? // empty' | sort -u | grep -v '^$' || true)
[ -n "$GRPCROUTE_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${GRPCROUTE_HOSTS}\n"

# 4. Gateway API TLSRoute (SNI-based)
TLSROUTE_HOSTS=$(kubectl get tlsroute -A -o json 2>/dev/null | jq -r '.items[].spec.hostnames[]? // empty' | sort -u | grep -v '^$' || true)
[ -n "$TLSROUTE_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${TLSROUTE_HOSTS}\n"

# 5. APISIX CRDs - ApisixRoute
APISIX_HOSTS=$(kubectl get apisixroute -A -o json 2>/dev/null | jq -r '.items[].spec.http[]?.match.hosts[]? // empty' | sort -u | grep -v '^$' || true)
[ -n "$APISIX_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${APISIX_HOSTS}\n"

# 6. Istio VirtualService (exclude wildcard hosts)
VIRTUALSERVICE_HOSTS=$(kubectl get virtualservice -A -o json 2>/dev/null | jq -r '.items[].spec.hosts[]? // empty' | grep -v '^\*' | sort -u | grep -v '^$' || true)
[ -n "$VIRTUALSERVICE_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${VIRTUALSERVICE_HOSTS}\n"

# 7. Traefik IngressRoute (parse Host(`...`) from match rules)
INGRESSROUTE_HOSTS=$(kubectl get ingressroute -A -o json 2>/dev/null | jq -r '.items[].spec.routes[]?.match // empty' | grep -oP 'Host\(`\K[^`]+' | sort -u || true)
[ -n "$INGRESSROUTE_HOSTS" ] && HOSTNAMES="${HOSTNAMES}${INGRESSROUTE_HOSTS}\n"

# Combine and deduplicate
HOSTNAMES=$(echo -e "$HOSTNAMES" | grep -v '^$' | sort -u)

if [ -z "$HOSTNAMES" ]; then
  log_warning "No routing resources found (Ingress, HTTPRoute, ApisixRoute, VirtualService, etc.)"
  log_info "Skipping HTTP tests (no endpoints to test)"
  exit 0
fi

log_info "Testing $(echo "$HOSTNAMES" | wc -l | xargs) endpoint(s)"

# =============================================================================
# Test HTTP endpoints
# =============================================================================

FAILED=0
PASSED=0

for hostname in $HOSTNAMES; do
  echo -n "  Testing https://$hostname... "

  # Use curl with Host header to simulate DNS resolution
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout "$TIMEOUT" \
    --max-time "$TIMEOUT" \
    -k \
    -H "Host: $hostname" \
    "https://$GATEWAY_IP/" 2>/dev/null || echo "000")

  # Acceptable status codes:
  # 2xx - Success
  # 3xx - Redirect (might redirect to login)
  # 401 - Unauthorized (service responding, needs auth)
  # 403 - Forbidden (service responding, access denied)
  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
    echo -e "${GREEN}OK${RESET} (HTTP $HTTP_CODE)"
    PASSED=$((PASSED + 1))
  elif [ "$HTTP_CODE" == "401" ] || [ "$HTTP_CODE" == "403" ]; then
    echo -e "${GREEN}OK${RESET} (HTTP $HTTP_CODE - Auth required)"
    PASSED=$((PASSED + 1))
  elif [ "$HTTP_CODE" == "000" ]; then
    echo -e "${RED}FAILED${RESET} (Connection error)"
    FAILED=$((FAILED + 1))
  else
    echo -e "${RED}FAILED${RESET} (HTTP $HTTP_CODE)"
    FAILED=$((FAILED + 1))
  fi
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== HTTP Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  log_error "$FAILED HTTP endpoint test(s) failed"
  exit 1
fi

log_success "All HTTP tests passed"
