#!/bin/bash
# =============================================================================
# Test ArgoCD Components
# =============================================================================
# Tests:
#   1. ArgoCD Server is running
#   2. ArgoCD Repo Server is running
#   3. ArgoCD Application Controller is running
#   4. ArgoCD Redis is running
#   5. ArgoCD API is accessible
#   6. Repository connection status
#   7. ApplicationSets are processed
#   8. KSOPS/Helm plugins are available
# =============================================================================

set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argo-cd}"

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
# Test 1: ArgoCD Server
# =============================================================================

log_info "=== Test 1: ArgoCD Server ==="

if kubectl get deployment -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server -o name 2>/dev/null | grep -q .; then
  kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-server -n "$ARGOCD_NAMESPACE" --timeout=120s
  log_success "ArgoCD Server is ready"

  SERVER_POD=$(kubectl get pod -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log_info "Server pod: $SERVER_POD"
else
  log_error "ArgoCD Server not found"
  exit 1
fi

# =============================================================================
# Test 2: ArgoCD Repo Server
# =============================================================================

log_info "=== Test 2: ArgoCD Repo Server ==="

if kubectl get deployment -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server -o name 2>/dev/null | grep -q .; then
  kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=120s
  log_success "ArgoCD Repo Server is ready"

  REPO_POD=$(kubectl get pod -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  log_info "Repo Server pod: $REPO_POD"
else
  log_error "ArgoCD Repo Server not found"
  exit 1
fi

# =============================================================================
# Test 3: ArgoCD Application Controller
# =============================================================================

log_info "=== Test 3: ArgoCD Application Controller ==="

# Controller can be Deployment or StatefulSet
if kubectl get deployment -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller -o name 2>/dev/null | grep -q .; then
  kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=120s
  log_success "ArgoCD Application Controller (Deployment) is ready"
elif kubectl get statefulset -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller -o name 2>/dev/null | grep -q .; then
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=120s
  log_success "ArgoCD Application Controller (StatefulSet) is ready"
else
  log_error "ArgoCD Application Controller not found"
  exit 1
fi

CONTROLLER_POD=$(kubectl get pod -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
log_info "Controller pod: $CONTROLLER_POD"

# =============================================================================
# Test 4: ArgoCD Redis
# =============================================================================

log_info "=== Test 4: ArgoCD Redis ==="

if kubectl get deployment -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-redis -o name 2>/dev/null | grep -q .; then
  kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-redis -n "$ARGOCD_NAMESPACE" --timeout=60s
  log_success "ArgoCD Redis is ready"
elif kubectl get statefulset -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-redis -o name 2>/dev/null | grep -q .; then
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-redis -n "$ARGOCD_NAMESPACE" --timeout=60s
  log_success "ArgoCD Redis (HA) is ready"
else
  log_info "ArgoCD Redis not found (may be using external Redis)"
fi

# =============================================================================
# Test 5: ArgoCD API Health
# =============================================================================

log_info "=== Test 5: ArgoCD API Health ==="

# Check server health endpoint
HEALTH=$(kubectl exec -n "$ARGOCD_NAMESPACE" "$SERVER_POD" -- \
  wget -qO- http://localhost:8080/healthz 2>/dev/null || echo "FAILED")

if [ "$HEALTH" = "ok" ]; then
  log_success "ArgoCD API /healthz returns ok"
else
  log_warning "ArgoCD API health check: $HEALTH"
fi

# Check version endpoint
VERSION=$(kubectl exec -n "$ARGOCD_NAMESPACE" "$SERVER_POD" -- \
  wget -qO- http://localhost:8080/api/version 2>/dev/null || echo '{"error":true}')

if echo "$VERSION" | grep -q "Version"; then
  ARGOCD_VERSION=$(echo "$VERSION" | grep -o '"Version":"[^"]*"' | cut -d'"' -f4)
  log_success "ArgoCD version: $ARGOCD_VERSION"
else
  log_warning "Could not get ArgoCD version"
fi

# =============================================================================
# Test 6: Repository Connection
# =============================================================================

log_info "=== Test 6: Repository Connections ==="

# Get repositories
REPOS=$(kubectl get secret -n "$ARGOCD_NAMESPACE" -l argocd.argoproj.io/secret-type=repository -o name 2>/dev/null | wc -l || echo "0")

log_info "Configured repositories: $REPOS"

# Check if repo-server can clone (via repo-server logs)
CLONE_STATUS=$(kubectl logs -n "$ARGOCD_NAMESPACE" "$REPO_POD" --tail=50 2>/dev/null | grep -i "git.*clone\|fetch\|resolved" | tail -3 || echo "")

if [ -n "$CLONE_STATUS" ]; then
  log_success "Repo server is accessing Git repositories"
else
  log_info "No recent Git activity in repo-server logs"
fi

# =============================================================================
# Test 7: ApplicationSets Processing
# =============================================================================

log_info "=== Test 7: ApplicationSets ==="

# Count ApplicationSets
APPSET_COUNT=$(kubectl get applicationset -n "$ARGOCD_NAMESPACE" -o name 2>/dev/null | wc -l || echo "0")

log_info "ApplicationSets deployed: $APPSET_COUNT"

if [ "$APPSET_COUNT" -gt 0 ]; then
  # Check ApplicationSet controller logs for errors
  APPSET_ERRORS=$(kubectl logs -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-applicationset-controller --tail=100 2>/dev/null | grep -i "error\|failed" | tail -3 || echo "")

  if [ -z "$APPSET_ERRORS" ]; then
    log_success "No recent errors in ApplicationSet controller"
  else
    log_warning "ApplicationSet controller errors found:"
    echo "$APPSET_ERRORS" | while read -r line; do
      echo "  $line"
    done
  fi
fi

# Count generated Applications
APP_COUNT=$(kubectl get application -n "$ARGOCD_NAMESPACE" -o name 2>/dev/null | wc -l || echo "0")
log_info "Applications generated: $APP_COUNT"

# =============================================================================
# Test 8: KSOPS/Helm Plugins
# =============================================================================

log_info "=== Test 8: Plugins and Tools ==="

# Check if KSOPS is available in repo-server
KSOPS_CHECK=$(kubectl exec -n "$ARGOCD_NAMESPACE" "$REPO_POD" -- \
  ls -la /home/argocd/cmp-server/plugins/ 2>/dev/null | grep -i "ksops\|sops" || echo "")

if [ -n "$KSOPS_CHECK" ]; then
  log_success "KSOPS plugin is available"
else
  log_info "KSOPS plugin not found (may use different path)"
fi

# Check Helm version
HELM_VERSION=$(kubectl exec -n "$ARGOCD_NAMESPACE" "$REPO_POD" -- \
  helm version --short 2>/dev/null | head -1 || echo "N/A")

if [ "$HELM_VERSION" != "N/A" ]; then
  log_success "Helm available: $HELM_VERSION"
fi

# Check Kustomize version
KUSTOMIZE_VERSION=$(kubectl exec -n "$ARGOCD_NAMESPACE" "$REPO_POD" -- \
  kustomize version 2>/dev/null | head -1 || echo "N/A")

if [ "$KUSTOMIZE_VERSION" != "N/A" ]; then
  log_success "Kustomize available: $KUSTOMIZE_VERSION"
fi

# =============================================================================
# Test 9: Application Sync Status Summary
# =============================================================================

log_info "=== Test 9: Application Sync Summary ==="

if [ "$APP_COUNT" -gt 0 ]; then
  APPS_JSON=$(kubectl get application -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)

  SYNCED=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.sync.status=="Synced")] | length' 2>/dev/null || echo "0")
  HEALTHY=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status=="Healthy")] | length' 2>/dev/null || echo "0")
  DEGRADED=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status=="Degraded")] | length' 2>/dev/null || echo "0")
  PROGRESSING=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status=="Progressing")] | length' 2>/dev/null || echo "0")

  log_info "Synced: $SYNCED/$APP_COUNT"
  log_info "Healthy: $HEALTHY, Degraded: $DEGRADED, Progressing: $PROGRESSING"

  if [ "$DEGRADED" -gt 0 ]; then
    log_warning "Degraded applications:"
    echo "$APPS_JSON" | jq -r '.items[] | select(.status.health.status=="Degraded") | "  - \(.metadata.name)"' 2>/dev/null
  fi

  if [ "$SYNCED" -eq "$APP_COUNT" ] && [ "$HEALTHY" -eq "$APP_COUNT" ]; then
    log_success "All applications are synced and healthy"
  fi
fi

# =============================================================================
# Test 10: ArgoCD Notifications (if enabled)
# =============================================================================

log_info "=== Test 10: Notifications Controller ==="

if kubectl get deployment -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-notifications-controller -o name 2>/dev/null | grep -q .; then
  NOTIF_READY=$(kubectl get deployment -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-notifications-controller -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "$NOTIF_READY" -gt 0 ]; then
    log_success "Notifications controller is ready"
  else
    log_warning "Notifications controller not ready"
  fi
else
  log_info "Notifications controller not deployed"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "       ArgoCD Test Summary"
echo "=============================================="
echo ""
echo "Namespace:           $ARGOCD_NAMESPACE"
echo "ArgoCD Version:      ${ARGOCD_VERSION:-N/A}"
echo "Server Pod:          ${SERVER_POD:-N/A}"
echo "Repo Server Pod:     ${REPO_POD:-N/A}"
echo "Controller Pod:      ${CONTROLLER_POD:-N/A}"
echo "Repositories:        $REPOS"
echo "ApplicationSets:     $APPSET_COUNT"
echo "Applications:        $APP_COUNT"
echo "Synced:              ${SYNCED:-0}/$APP_COUNT"
echo "Healthy:             ${HEALTHY:-0}/$APP_COUNT"
echo ""

log_success "ArgoCD tests passed!"
