#!/bin/bash
# =============================================================================
# Test for unexpected packet drops in Hubble
# =============================================================================
# Checks Hubble for dropped packets and fails if there are unexpected drops
# in critical namespaces. Policy denies are expected and not counted as failures.
# =============================================================================

set -euo pipefail

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

# Critical namespaces where drops indicate a problem
CRITICAL_NAMESPACES="argo-cd kube-system cert-manager"

# =============================================================================
# Find Cilium pod
# =============================================================================

log_info "Checking Hubble for unexpected packet drops"

CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$CILIUM_POD" ]; then
  log_warning "Cilium pod not found, skipping Hubble test"
  exit 0
fi

log_info "Using Cilium pod: $CILIUM_POD"

# =============================================================================
# Wait for Hubble to be ready
# =============================================================================

log_info "Checking Hubble status..."

# Check if hubble observe works
if ! kubectl exec -n kube-system "$CILIUM_POD" -- hubble observe --last 1 &>/dev/null; then
  log_warning "Hubble not ready or not available, skipping test"
  exit 0
fi

# =============================================================================
# Get recent drops
# =============================================================================

log_info "Fetching recent dropped packets..."

DROPS_JSON=$(kubectl exec -n kube-system "$CILIUM_POD" -- \
  hubble observe --verdict DROPPED --last 100 -o json 2>/dev/null || echo "")

if [ -z "$DROPS_JSON" ] || [ "$DROPS_JSON" == "" ]; then
  log_success "No drops detected in recent flows"
  exit 0
fi

# Parse drops
DROP_COUNT=$(echo "$DROPS_JSON" | jq -s 'length' 2>/dev/null || echo "0")

if [ "$DROP_COUNT" -eq 0 ]; then
  log_success "No drops detected in recent flows"
  exit 0
fi

log_info "Found $DROP_COUNT dropped packets in recent flows"

# =============================================================================
# Analyze drops
# =============================================================================

# Filter for policy denied (expected)
POLICY_DENIED_COUNT=$(echo "$DROPS_JSON" | jq -s '[.[] | select(.drop_reason_desc == "POLICY_DENIED")] | length' 2>/dev/null || echo "0")

# Filter for unexpected drops (not policy denied)
UNEXPECTED_DROPS=$(echo "$DROPS_JSON" | jq -s '[.[] | select(.drop_reason_desc != "POLICY_DENIED" and .drop_reason_desc != null)]' 2>/dev/null || echo "[]")
UNEXPECTED_COUNT=$(echo "$UNEXPECTED_DROPS" | jq 'length' 2>/dev/null || echo "0")

log_info "Policy denied drops (expected): $POLICY_DENIED_COUNT"
log_info "Other drops: $UNEXPECTED_COUNT"

# =============================================================================
# Check for drops in critical namespaces
# =============================================================================

CRITICAL_DROPS=0

for ns in $CRITICAL_NAMESPACES; do
  NS_DROPS=$(echo "$UNEXPECTED_DROPS" | jq -r "[.[] | select(.destination.namespace == \"$ns\" or .source.namespace == \"$ns\")] | length" 2>/dev/null || echo "0")

  if [ "$NS_DROPS" -gt 0 ]; then
    log_warning "Found $NS_DROPS unexpected drops involving namespace: $ns"
    CRITICAL_DROPS=$((CRITICAL_DROPS + NS_DROPS))

    # Show details
    echo "$UNEXPECTED_DROPS" | jq -r ".[] | select(.destination.namespace == \"$ns\" or .source.namespace == \"$ns\") | \"  \\(.source.namespace)/\\(.source.pod_name // \"unknown\") -> \\(.destination.namespace)/\\(.destination.pod_name // \"unknown\") [\\(.drop_reason_desc)]\"" 2>/dev/null | head -10
  fi
done

# =============================================================================
# Show summary of all drops (for debugging)
# =============================================================================

if [ "$UNEXPECTED_COUNT" -gt 0 ]; then
  echo ""
  log_info "All unexpected drops (up to 20):"
  echo "$UNEXPECTED_DROPS" | jq -r '.[] | "\(.time): \(.source.namespace // "?")/\(.source.pod_name // "?") -> \(.destination.namespace // "?")/\(.destination.pod_name // "?") [\(.drop_reason_desc)]"' 2>/dev/null | head -20
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Hubble Drop Summary ==="
echo "Total drops analyzed: $DROP_COUNT"
echo "Policy denied (expected): $POLICY_DENIED_COUNT"
echo "Unexpected drops: $UNEXPECTED_COUNT"
echo "Critical namespace drops: $CRITICAL_DROPS"

if [ "$CRITICAL_DROPS" -gt 0 ]; then
  log_error "Found $CRITICAL_DROPS unexpected drops in critical namespaces"
  exit 1
fi

if [ "$UNEXPECTED_COUNT" -gt 10 ]; then
  log_warning "High number of unexpected drops ($UNEXPECTED_COUNT), but none in critical namespaces"
fi

log_success "Hubble test passed (no critical drops)"
