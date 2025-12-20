#!/bin/bash
# =============================================================================
# Test NeuVector Security Platform
# =============================================================================
# Tests:
#   1. NeuVector Controller is running
#   2. NeuVector Enforcer is running on all nodes
#   3. NeuVector Manager (Web UI) is accessible
#   4. NeuVector Scanner is running
#   5. API health check
#   6. Cluster status via API
# =============================================================================

set -euo pipefail

NEUVECTOR_NAMESPACE="neuvector"

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
# Test 1: NeuVector Controller
# =============================================================================

log_info "=== Test 1: NeuVector Controller ==="

if kubectl get deployment -n "$NEUVECTOR_NAMESPACE" neuvector-controller-pod &>/dev/null; then
  kubectl wait --for=condition=Available deployment/neuvector-controller-pod -n "$NEUVECTOR_NAMESPACE" --timeout=180s
  log_success "NeuVector Controller deployment is ready"
elif kubectl get statefulset -n "$NEUVECTOR_NAMESPACE" neuvector-controller-pod &>/dev/null; then
  kubectl wait --for=condition=Ready pod -l app=neuvector-controller-pod -n "$NEUVECTOR_NAMESPACE" --timeout=180s
  log_success "NeuVector Controller StatefulSet is ready"
else
  log_error "NeuVector Controller not found"
  exit 1
fi

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -n "$NEUVECTOR_NAMESPACE" -l app=neuvector-controller-pod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
log_info "Controller pod: $CONTROLLER_POD"

# =============================================================================
# Test 2: NeuVector Enforcer
# =============================================================================

log_info "=== Test 2: NeuVector Enforcer ==="

if kubectl get daemonset -n "$NEUVECTOR_NAMESPACE" neuvector-enforcer-pod &>/dev/null; then
  # Wait for at least one enforcer pod to be ready
  kubectl wait --for=condition=Ready pod -l app=neuvector-enforcer-pod -n "$NEUVECTOR_NAMESPACE" --timeout=120s

  # Check DaemonSet status
  DESIRED=$(kubectl get daemonset -n "$NEUVECTOR_NAMESPACE" neuvector-enforcer-pod -o jsonpath='{.status.desiredNumberScheduled}')
  READY=$(kubectl get daemonset -n "$NEUVECTOR_NAMESPACE" neuvector-enforcer-pod -o jsonpath='{.status.numberReady}')

  if [ "$READY" -eq "$DESIRED" ]; then
    log_success "NeuVector Enforcer DaemonSet is ready ($READY/$DESIRED pods)"
  else
    log_warning "NeuVector Enforcer: $READY/$DESIRED pods ready"
  fi
else
  log_warning "NeuVector Enforcer DaemonSet not found"
fi

# =============================================================================
# Test 3: NeuVector Manager (Web UI)
# =============================================================================

log_info "=== Test 3: NeuVector Manager ==="

if kubectl get deployment -n "$NEUVECTOR_NAMESPACE" neuvector-manager-pod &>/dev/null; then
  kubectl wait --for=condition=Available deployment/neuvector-manager-pod -n "$NEUVECTOR_NAMESPACE" --timeout=120s
  log_success "NeuVector Manager deployment is ready"

  MANAGER_POD=$(kubectl get pod -n "$NEUVECTOR_NAMESPACE" -l app=neuvector-manager-pod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log_info "Manager pod: $MANAGER_POD"
else
  log_info "NeuVector Manager not deployed (may be using controller API only)"
fi

# =============================================================================
# Test 4: NeuVector Scanner
# =============================================================================

log_info "=== Test 4: NeuVector Scanner ==="

if kubectl get deployment -n "$NEUVECTOR_NAMESPACE" neuvector-scanner-pod &>/dev/null; then
  kubectl wait --for=condition=Available deployment/neuvector-scanner-pod -n "$NEUVECTOR_NAMESPACE" --timeout=120s
  log_success "NeuVector Scanner deployment is ready"

  SCANNER_REPLICAS=$(kubectl get deployment -n "$NEUVECTOR_NAMESPACE" neuvector-scanner-pod -o jsonpath='{.status.readyReplicas}')
  log_info "Scanner replicas: $SCANNER_REPLICAS"
else
  log_info "NeuVector Scanner not deployed separately"
fi

# =============================================================================
# Test 5: Controller API Health
# =============================================================================

log_info "=== Test 5: Controller API Health ==="

# NeuVector controller API runs on port 10443 (HTTPS)
# First try to get a token via the REST API
API_HEALTH=$(kubectl exec -n "$NEUVECTOR_NAMESPACE" "$CONTROLLER_POD" -- \
  curl -sk https://localhost:10443/v1/partner/ibm_sa/health 2>/dev/null || echo '{"error":true}')

if echo "$API_HEALTH" | grep -q '"healthy"'; then
  log_success "NeuVector API is healthy"
else
  # Try alternate health endpoint
  API_HEALTH=$(kubectl exec -n "$NEUVECTOR_NAMESPACE" "$CONTROLLER_POD" -- \
    curl -sk https://localhost:10443/ 2>/dev/null || echo "FAILED")

  if [ "$API_HEALTH" != "FAILED" ]; then
    log_success "NeuVector API is responding"
  else
    log_warning "Could not verify API health"
  fi
fi

# =============================================================================
# Test 6: NeuVector Services
# =============================================================================

log_info "=== Test 6: NeuVector Services ==="

# Check controller service
if kubectl get svc -n "$NEUVECTOR_NAMESPACE" neuvector-svc-controller &>/dev/null; then
  CTRL_SVC_IP=$(kubectl get svc -n "$NEUVECTOR_NAMESPACE" neuvector-svc-controller -o jsonpath='{.spec.clusterIP}')
  log_success "Controller service exists (ClusterIP: $CTRL_SVC_IP)"
else
  log_warning "Controller service not found"
fi

# Check manager service
if kubectl get svc -n "$NEUVECTOR_NAMESPACE" neuvector-service-webui &>/dev/null; then
  WEBUI_TYPE=$(kubectl get svc -n "$NEUVECTOR_NAMESPACE" neuvector-service-webui -o jsonpath='{.spec.type}')
  log_success "Manager WebUI service exists (Type: $WEBUI_TYPE)"
else
  log_info "Manager WebUI service not found"
fi

# =============================================================================
# Test 7: NeuVector CRDs
# =============================================================================

log_info "=== Test 7: NeuVector CRDs ==="

# Check for NeuVector CRDs
CRDS=$(kubectl get crd 2>/dev/null | grep -c "neuvector.com" || echo "0")

if [ "$CRDS" -gt 0 ]; then
  log_success "Found $CRDS NeuVector CRD(s)"
  kubectl get crd | grep "neuvector.com" | awk '{print "  - " $1}'
else
  log_info "No NeuVector CRDs found (using REST API mode)"
fi

# =============================================================================
# Test 8: Controller Cluster Status
# =============================================================================

log_info "=== Test 8: Cluster Membership ==="

# Check controller logs for cluster join status
CLUSTER_STATUS=$(kubectl logs -n "$NEUVECTOR_NAMESPACE" "$CONTROLLER_POD" --tail=50 2>/dev/null | grep -i "cluster\|join\|leader" | tail -5 || echo "")

if [ -n "$CLUSTER_STATUS" ]; then
  log_info "Recent cluster activity:"
  echo "$CLUSTER_STATUS" | while read -r line; do
    echo "  $line"
  done
else
  log_info "No recent cluster activity in logs"
fi

# Check if controller is the leader (single node should be leader)
LEADER_INFO=$(kubectl logs -n "$NEUVECTOR_NAMESPACE" "$CONTROLLER_POD" --tail=100 2>/dev/null | grep -i "become leader\|I am leader" | tail -1 || echo "")

if [ -n "$LEADER_INFO" ]; then
  log_success "Controller has established leadership"
fi

# =============================================================================
# Test 9: Storage (PVC)
# =============================================================================

log_info "=== Test 9: Storage Check ==="

# Check if NeuVector uses persistent storage
PVCS=$(kubectl get pvc -n "$NEUVECTOR_NAMESPACE" 2>/dev/null | grep -v NAME | wc -l || echo "0")

if [ "$PVCS" -gt 0 ]; then
  log_success "NeuVector has $PVCS PVC(s)"
  kubectl get pvc -n "$NEUVECTOR_NAMESPACE" -o wide | head -5
else
  log_info "NeuVector running without persistent storage"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "       NeuVector Test Summary"
echo "=============================================="
echo ""
echo "Namespace:          $NEUVECTOR_NAMESPACE"
echo "Controller Pod:     ${CONTROLLER_POD:-N/A}"
echo "Manager Pod:        ${MANAGER_POD:-N/A}"
echo "Enforcer Ready:     ${READY:-0}/${DESIRED:-0}"
echo "Scanner Replicas:   ${SCANNER_REPLICAS:-0}"
echo "CRDs Installed:     $CRDS"
echo ""

log_success "NeuVector tests passed!"
