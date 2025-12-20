#!/bin/bash
# =============================================================================
# Wait for ArgoCD applications to be synced and healthy
# =============================================================================
# Monitors ArgoCD Applications until all are Synced+Healthy or timeout
# =============================================================================

set -euo pipefail

TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-900}"  # 15 minutes default
INTERVAL=10
ELAPSED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# =============================================================================
# Main
# =============================================================================

log_info "Waiting for ArgoCD applications to be healthy (timeout: ${TIMEOUT}s)..."

while true; do
  # Get all applications
  APPS_JSON=$(kubectl get application -A -o json 2>/dev/null || echo '{"items":[]}')

  TOTAL=$(echo "$APPS_JSON" | jq '.items | length')

  if [ "$TOTAL" -eq 0 ]; then
    log_warning "No applications found yet..."
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
      log_error "Timeout: No applications were created"
      exit 1
    fi
    continue
  fi

  SYNCED=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.sync.status=="Synced")] | length')
  HEALTHY=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status=="Healthy")] | length')
  SYNCED_HEALTHY=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')
  DEGRADED=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status=="Degraded")] | length')
  PROGRESSING=$(echo "$APPS_JSON" | jq '[.items[] | select(.status.health.status=="Progressing")] | length')

  PROGRESS=$((SYNCED_HEALTHY * 100 / TOTAL))

  echo -ne "\r[$ELAPSED s] Apps: $SYNCED_HEALTHY/$TOTAL synced+healthy ($PROGRESS%) | Synced: $SYNCED | Healthy: $HEALTHY | Progressing: $PROGRESSING | Degraded: $DEGRADED   "

  # All apps synced and healthy
  if [ "$SYNCED_HEALTHY" -ge "$TOTAL" ]; then
    echo ""
    log_success "All $TOTAL applications are synced and healthy!"
    echo ""
    echo "=== Application Status ==="
    kubectl get application -A -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
    exit 0
  fi

  # Timeout check
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo ""
    log_error "Timeout after ${TIMEOUT}s waiting for applications"
    echo ""
    echo "=== Application Status ==="
    kubectl get application -A -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,MESSAGE:.status.conditions

    # Show degraded apps details
    if [ "$DEGRADED" -gt 0 ]; then
      echo ""
      echo "=== Degraded Applications ==="
      echo "$APPS_JSON" | jq -r '.items[] | select(.status.health.status=="Degraded") | "\(.metadata.name): \(.status.health.message // "no message")"'
    fi

    # Show not synced apps
    NOT_SYNCED=$(echo "$APPS_JSON" | jq -r '.items[] | select(.status.sync.status!="Synced") | .metadata.name')
    if [ -n "$NOT_SYNCED" ]; then
      echo ""
      echo "=== Not Synced Applications ==="
      echo "$NOT_SYNCED"
    fi

    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
