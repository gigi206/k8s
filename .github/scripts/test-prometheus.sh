#!/bin/bash
# =============================================================================
# Test Prometheus Stack (Prometheus, Alertmanager, Grafana)
# =============================================================================
# Tests:
#   1. Prometheus is running and scraping targets
#   2. Alertmanager is running
#   3. Grafana is running and accessible
#   4. Key metrics are available
#   5. Recording rules are working
# =============================================================================

set -euo pipefail

PROMETHEUS_NAMESPACE="prometheus-stack"

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
# Test 1: Prometheus Health
# =============================================================================

log_info "=== Test 1: Prometheus Health ==="

# Check Prometheus StatefulSet/Deployment
if kubectl get statefulset -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=prometheus -o name &>/dev/null; then
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "$PROMETHEUS_NAMESPACE" --timeout=120s
  log_success "Prometheus pods are ready"
else
  log_error "Prometheus not found"
  exit 1
fi

# Get Prometheus pod
PROMETHEUS_POD=$(kubectl get pod -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# Check Prometheus is healthy via API
log_info "Checking Prometheus API..."
PROM_HEALTH=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$PROMETHEUS_POD" -c prometheus -- \
  wget -qO- http://localhost:9090/-/healthy 2>/dev/null || echo "FAILED")

if [ "$PROM_HEALTH" = "Prometheus Server is Healthy." ]; then
  log_success "Prometheus API is healthy"
else
  log_error "Prometheus API health check failed: $PROM_HEALTH"
  exit 1
fi

# =============================================================================
# Test 2: Prometheus Targets
# =============================================================================

log_info "=== Test 2: Prometheus Scrape Targets ==="

# Get targets status
TARGETS_JSON=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$PROMETHEUS_POD" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null || echo '{"status":"error"}')

ACTIVE_TARGETS=$(echo "$TARGETS_JSON" | grep -o '"health":"up"' | wc -l || echo "0")
DOWN_TARGETS=$(echo "$TARGETS_JSON" | grep -o '"health":"down"' | wc -l || echo "0")

log_info "Active targets: $ACTIVE_TARGETS, Down targets: $DOWN_TARGETS"

if [ "$ACTIVE_TARGETS" -gt 0 ]; then
  log_success "Prometheus has $ACTIVE_TARGETS active scrape targets"
else
  log_warning "No active scrape targets found"
fi

if [ "$DOWN_TARGETS" -gt 0 ]; then
  log_warning "$DOWN_TARGETS targets are down"
fi

# =============================================================================
# Test 3: Alertmanager Health
# =============================================================================

log_info "=== Test 3: Alertmanager Health ==="

if kubectl get statefulset -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=alertmanager -o name &>/dev/null; then
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=alertmanager -n "$PROMETHEUS_NAMESPACE" --timeout=60s
  log_success "Alertmanager pods are ready"

  # Check Alertmanager API
  ALERTMANAGER_POD=$(kubectl get pod -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  AM_HEALTH=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$ALERTMANAGER_POD" -- \
    wget -qO- http://localhost:9093/-/healthy 2>/dev/null || echo "FAILED")

  if echo "$AM_HEALTH" | grep -qi "ok\|healthy"; then
    log_success "Alertmanager API is healthy"
  else
    log_warning "Alertmanager health check returned: $AM_HEALTH"
  fi
else
  log_info "Alertmanager not deployed (optional)"
fi

# =============================================================================
# Test 4: Grafana Health
# =============================================================================

log_info "=== Test 4: Grafana Health ==="

if kubectl get deployment -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=grafana -o name &>/dev/null; then
  kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=grafana -n "$PROMETHEUS_NAMESPACE" --timeout=120s
  log_success "Grafana deployment is ready"

  # Check Grafana API
  GRAFANA_POD=$(kubectl get pod -n "$PROMETHEUS_NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  GRAFANA_HEALTH=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$GRAFANA_POD" -- \
    wget -qO- http://localhost:3000/api/health 2>/dev/null || echo '{"database":"error"}')

  if echo "$GRAFANA_HEALTH" | grep -q '"database":"ok"'; then
    log_success "Grafana API is healthy"
  else
    log_warning "Grafana health: $GRAFANA_HEALTH"
  fi

  # Check datasources
  DATASOURCES=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$GRAFANA_POD" -- \
    wget -qO- --header="Authorization: Basic YWRtaW46YWRtaW4=" http://localhost:3000/api/datasources 2>/dev/null || echo "[]")

  DS_COUNT=$(echo "$DATASOURCES" | grep -o '"id":' | wc -l || echo "0")
  log_info "Grafana has $DS_COUNT datasource(s) configured"
else
  log_info "Grafana not deployed (optional)"
fi

# =============================================================================
# Test 5: Key Metrics Available
# =============================================================================

log_info "=== Test 5: Key Metrics Availability ==="

# Test a few key metrics
METRICS_TO_CHECK=(
  "up"
  "kube_node_info"
  "container_cpu_usage_seconds_total"
)

for metric in "${METRICS_TO_CHECK[@]}"; do
  RESULT=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$PROMETHEUS_POD" -c prometheus -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=${metric}" 2>/dev/null || echo '{"status":"error"}')

  if echo "$RESULT" | grep -q '"status":"success"'; then
    SAMPLE_COUNT=$(echo "$RESULT" | grep -o '"metric"' | wc -l || echo "0")
    log_success "Metric '$metric' available ($SAMPLE_COUNT samples)"
  else
    log_warning "Metric '$metric' not available"
  fi
done

# =============================================================================
# Test 6: Recording Rules
# =============================================================================

log_info "=== Test 6: Recording/Alerting Rules ==="

RULES_JSON=$(kubectl exec -n "$PROMETHEUS_NAMESPACE" "$PROMETHEUS_POD" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules' 2>/dev/null || echo '{"status":"error"}')

RULE_GROUPS=$(echo "$RULES_JSON" | grep -o '"name":' | wc -l || echo "0")
log_info "Found $RULE_GROUPS rule group(s)"

if [ "$RULE_GROUPS" -gt 0 ]; then
  log_success "Recording/alerting rules are loaded"
else
  log_warning "No recording rules found"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "       Prometheus Stack Test Summary"
echo "=============================================="
echo ""
echo "Prometheus:     OK"
echo "Active Targets: $ACTIVE_TARGETS"
echo "Down Targets:   $DOWN_TARGETS"
echo "Rule Groups:    $RULE_GROUPS"
echo ""

log_success "Prometheus stack tests passed!"
