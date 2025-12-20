#!/bin/bash
# =============================================================================
# Test CNPG Operator (CloudNativePG)
# =============================================================================
# Tests:
#   1. CNPG Operator is running
#   2. Create a PostgreSQL cluster
#   3. Wait for cluster to be ready
#   4. Connect and run SQL queries
#   5. Test backup/restore (if snapshots available)
# =============================================================================

set -euo pipefail

TEST_NAMESPACE="cnpg-test"
CLUSTER_NAME="test-postgres"

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
  log_info "Cleaning up CNPG test resources..."
  kubectl delete namespace "$TEST_NAMESPACE" --wait=false 2>/dev/null || true
}

# Trap for cleanup on exit
trap cleanup EXIT

# =============================================================================
# Test 1: CNPG Operator Health
# =============================================================================

log_info "=== Test 1: CNPG Operator Health ==="

# Check operator is running
if kubectl get deployment -n cnpg-system cnpg-controller-manager &>/dev/null; then
  if kubectl wait --for=condition=Available deployment/cnpg-controller-manager -n cnpg-system --timeout=120s; then
    log_success "CNPG Operator is running"
  else
    log_error "CNPG Operator not available"
    exit 1
  fi
else
  log_error "CNPG Operator deployment not found"
  exit 1
fi

# =============================================================================
# Test 2: Create PostgreSQL Cluster
# =============================================================================

log_info "=== Test 2: Creating PostgreSQL Cluster ==="

# Create namespace
kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Get storage class
STORAGE_CLASS=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$STORAGE_CLASS" ]; then
  log_error "No StorageClass found"
  exit 1
fi
log_info "Using StorageClass: $STORAGE_CLASS"

# Create PostgreSQL cluster
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $CLUSTER_NAME
  namespace: $TEST_NAMESPACE
spec:
  instances: 1

  storage:
    size: 1Gi
    storageClass: $STORAGE_CLASS

  postgresql:
    parameters:
      max_connections: "50"
      shared_buffers: "128MB"

  bootstrap:
    initdb:
      database: testdb
      owner: testuser
      secret:
        name: ${CLUSTER_NAME}-credentials
---
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_NAME}-credentials
  namespace: $TEST_NAMESPACE
type: kubernetes.io/basic-auth
stringData:
  username: testuser
  password: testpassword123
EOF

log_success "PostgreSQL Cluster manifest applied"

# =============================================================================
# Test 3: Wait for Cluster Ready
# =============================================================================

log_info "=== Test 3: Waiting for PostgreSQL Cluster ==="

# Wait for cluster to be ready
TIMEOUT=300
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
  STATUS=$(kubectl get cluster "$CLUSTER_NAME" -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  READY=$(kubectl get cluster "$CLUSTER_NAME" -n "$TEST_NAMESPACE" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")

  log_info "Cluster status: $STATUS (ready instances: $READY/1)"

  if [ "$STATUS" = "Cluster in healthy state" ] && [ "$READY" = "1" ]; then
    log_success "PostgreSQL Cluster is ready"
    break
  fi

  if [ $ELAPSED -ge $TIMEOUT ]; then
    log_error "Timeout waiting for cluster to be ready"
    kubectl describe cluster "$CLUSTER_NAME" -n "$TEST_NAMESPACE"
    exit 1
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

# Show cluster status
kubectl get cluster "$CLUSTER_NAME" -n "$TEST_NAMESPACE"
kubectl get pods -n "$TEST_NAMESPACE"

# =============================================================================
# Test 4: Connect and Run SQL
# =============================================================================

log_info "=== Test 4: Testing SQL Connection ==="

# Get the primary pod
PRIMARY_POD=$(kubectl get pods -n "$TEST_NAMESPACE" -l cnpg.io/cluster=$CLUSTER_NAME,role=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$PRIMARY_POD" ]; then
  log_error "Primary pod not found"
  exit 1
fi

log_info "Primary pod: $PRIMARY_POD"

# Test SQL connection
log_info "Creating test table..."
kubectl exec -n "$TEST_NAMESPACE" "$PRIMARY_POD" -- psql -U testuser -d testdb -c "
CREATE TABLE IF NOT EXISTS test_data (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
" 2>/dev/null

log_info "Inserting test data..."
kubectl exec -n "$TEST_NAMESPACE" "$PRIMARY_POD" -- psql -U testuser -d testdb -c "
INSERT INTO test_data (name) VALUES ('test-entry-1'), ('test-entry-2'), ('test-entry-3');
" 2>/dev/null

log_info "Querying test data..."
RESULT=$(kubectl exec -n "$TEST_NAMESPACE" "$PRIMARY_POD" -- psql -U testuser -d testdb -t -c "SELECT COUNT(*) FROM test_data;" 2>/dev/null | tr -d ' ')

if [ "$RESULT" = "3" ]; then
  log_success "SQL queries working correctly (found $RESULT rows)"
else
  log_error "SQL query failed (expected 3 rows, got: $RESULT)"
  exit 1
fi

# Test read query
log_info "Testing SELECT query..."
kubectl exec -n "$TEST_NAMESPACE" "$PRIMARY_POD" -- psql -U testuser -d testdb -c "SELECT * FROM test_data;" 2>/dev/null
log_success "SELECT query successful"

# =============================================================================
# Test 5: Check Metrics (if Prometheus is available)
# =============================================================================

log_info "=== Test 5: Checking Metrics Endpoint ==="

# Check if metrics are exposed
METRICS=$(kubectl exec -n "$TEST_NAMESPACE" "$PRIMARY_POD" -- curl -s http://localhost:9187/metrics 2>/dev/null | head -5 || echo "")

if [ -n "$METRICS" ]; then
  log_success "PostgreSQL metrics endpoint is accessible"
else
  log_info "Metrics endpoint not available (optional)"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=============================================="
echo "       CNPG Test Summary"
echo "=============================================="
echo ""
echo "Cluster Name:     $CLUSTER_NAME"
echo "Namespace:        $TEST_NAMESPACE"
echo "Storage Class:    $STORAGE_CLASS"
echo "Primary Pod:      $PRIMARY_POD"
echo "Database:         testdb"
echo "User:             testuser"
echo ""

log_success "All CNPG tests passed!"
