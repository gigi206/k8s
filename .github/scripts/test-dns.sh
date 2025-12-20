#!/bin/bash
# =============================================================================
# Test DNS resolution for k8s.lan domain
# =============================================================================
# Verifies that DNS resolution works for all configured hostnames
# =============================================================================

set -euo pipefail

DOMAIN="${DOMAIN:-k8s.lan}"

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
# Find DNS server
# =============================================================================

log_info "Testing DNS resolution for $DOMAIN"

# Try to find external-dns CoreDNS service
DNS_SERVER=""
EXTERNAL_DNS_SVC=$(kubectl get svc -n external-dns -l app.kubernetes.io/name=coredns -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)

if [ -n "$EXTERNAL_DNS_SVC" ]; then
  DNS_SERVER="$EXTERNAL_DNS_SVC"
  log_info "Using external-dns CoreDNS at $DNS_SERVER"
else
  # Fallback to kube-dns
  DNS_SERVER=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [ -n "$DNS_SERVER" ]; then
    log_info "Using cluster DNS (kube-dns) at $DNS_SERVER"
  else
    log_warning "No DNS server found, skipping DNS tests"
    exit 0
  fi
fi

# =============================================================================
# Get hostnames from HTTPRoutes and Ingresses
# =============================================================================

HOSTNAMES=$(kubectl get httproute,ingress -A -o json 2>/dev/null | jq -r '
  .items[] |
  if .kind == "HTTPRoute" then .spec.hostnames[]?
  elif .kind == "Ingress" then .spec.rules[]?.host
  else empty end
' | sort -u | grep -v '^$' | grep -v '^null$' || true)

if [ -z "$HOSTNAMES" ]; then
  log_warning "No HTTPRoutes or Ingresses found with hostnames"
  log_info "Testing base domain resolution..."

  # Test at least the base domain
  HOSTNAMES="$DOMAIN"
fi

log_info "Testing DNS resolution for $(echo "$HOSTNAMES" | wc -w | xargs) hostname(s)"

# =============================================================================
# Test DNS resolution
# =============================================================================

FAILED=0
PASSED=0

for hostname in $HOSTNAMES; do
  echo -n "  Testing $hostname... "

  # Use dig or nslookup
  if command -v dig &>/dev/null; then
    RESULT=$(dig +short "$hostname" "@$DNS_SERVER" 2>/dev/null || true)
  elif command -v nslookup &>/dev/null; then
    RESULT=$(nslookup "$hostname" "$DNS_SERVER" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' || true)
  else
    # Fallback: try getent
    RESULT=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}' || true)
  fi

  if [ -n "$RESULT" ]; then
    echo -e "${GREEN}OK${RESET} ($RESULT)"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}FAILED${RESET}"
    FAILED=$((FAILED + 1))
  fi
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== DNS Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  log_error "$FAILED DNS resolution test(s) failed"
  exit 1
fi

log_success "All DNS tests passed"
