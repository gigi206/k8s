#!/bin/bash
# =============================================================================
# Test storage functionality with PVC and Snapshots
# =============================================================================
# Tests:
#   1. Create PVC and verify it becomes Bound
#   2. Write data to PVC via Pod
#   3. Create VolumeSnapshot
#   4. Restore PVC from snapshot
#   5. Verify restored data matches original
# =============================================================================

set -euo pipefail

STORAGE_PROVIDER="${STORAGE_PROVIDER:-none}"
TEST_NAMESPACE="storage-test"
TEST_DATA="test-data-$(date +%s)"

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
  log_info "Cleaning up test resources..."
  kubectl delete namespace "$TEST_NAMESPACE" --wait=false 2>/dev/null || true
}

# =============================================================================
# Pre-checks
# =============================================================================

# Skip if no storage provider
if [ "$STORAGE_PROVIDER" == "none" ] || [ -z "$STORAGE_PROVIDER" ]; then
  log_info "No storage provider configured, skipping storage tests"
  exit 0
fi

log_info "Testing storage provider: $STORAGE_PROVIDER"

# Determine StorageClass and SnapshotClass
case "$STORAGE_PROVIDER" in
  longhorn)
    STORAGE_CLASS="longhorn"
    SNAPSHOT_CLASS="longhorn-snapshot"
    ;;
  rook)
    STORAGE_CLASS="ceph-block"
    SNAPSHOT_CLASS="ceph-block-snapshot"
    ;;
  *)
    log_error "Unknown storage provider: $STORAGE_PROVIDER"
    exit 1
    ;;
esac

log_info "Using StorageClass: $STORAGE_CLASS"
log_info "Using VolumeSnapshotClass: $SNAPSHOT_CLASS"

# Verify StorageClass exists
if ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
  log_error "StorageClass '$STORAGE_CLASS' not found"
  kubectl get storageclass
  exit 1
fi

# Verify VolumeSnapshotClass exists
if ! kubectl get volumesnapshotclass "$SNAPSHOT_CLASS" &>/dev/null; then
  log_warning "VolumeSnapshotClass '$SNAPSHOT_CLASS' not found, snapshot tests will be skipped"
  SKIP_SNAPSHOT=true
else
  SKIP_SNAPSHOT=false
fi

# =============================================================================
# Setup
# =============================================================================

# Create test namespace
kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Trap for cleanup on exit
trap cleanup EXIT

# =============================================================================
# Test 1: Create PVC
# =============================================================================

log_info "=== Test 1: Creating PVC ==="

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: $TEST_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for PVC to be bound
log_info "Waiting for PVC to be Bound..."
if kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/test-pvc -n "$TEST_NAMESPACE" --timeout=180s; then
  log_success "PVC is Bound"
else
  log_error "PVC failed to become Bound"
  kubectl describe pvc/test-pvc -n "$TEST_NAMESPACE"
  exit 1
fi

# =============================================================================
# Test 2: Write data to PVC
# =============================================================================

log_info "=== Test 2: Writing data to PVC ==="

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-writer
  namespace: $TEST_NAMESPACE
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "$TEST_DATA" > /data/test.txt
          echo "Data written: \$(cat /data/test.txt)"
          # Keep pod running briefly for verification
          sleep 10
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-pvc
  restartPolicy: Never
EOF

# Wait for pod to complete
log_info "Waiting for writer pod to complete..."
if kubectl wait --for=condition=Ready pod/test-writer -n "$TEST_NAMESPACE" --timeout=120s; then
  log_info "Writer pod is ready"
else
  log_error "Writer pod failed to become ready"
  kubectl describe pod/test-writer -n "$TEST_NAMESPACE"
  kubectl logs test-writer -n "$TEST_NAMESPACE" 2>/dev/null || true
  exit 1
fi

# Wait for completion
sleep 15
if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-writer -n "$TEST_NAMESPACE" --timeout=60s 2>/dev/null; then
  log_success "Data written successfully"
  kubectl logs test-writer -n "$TEST_NAMESPACE"
else
  # Check if it's still running or failed
  POD_STATUS=$(kubectl get pod/test-writer -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}')
  if [ "$POD_STATUS" == "Running" ]; then
    log_success "Data written (pod still running)"
    kubectl logs test-writer -n "$TEST_NAMESPACE"
  else
    log_error "Writer pod failed: $POD_STATUS"
    kubectl logs test-writer -n "$TEST_NAMESPACE" 2>/dev/null || true
    exit 1
  fi
fi

# Delete writer pod before snapshot
kubectl delete pod/test-writer -n "$TEST_NAMESPACE" --wait=true

# =============================================================================
# Test 3: Create Snapshot
# =============================================================================

if [ "$SKIP_SNAPSHOT" == "true" ]; then
  log_warning "=== Test 3: Skipping Snapshot (VolumeSnapshotClass not found) ==="
else
  log_info "=== Test 3: Creating VolumeSnapshot ==="

  cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
  namespace: $TEST_NAMESPACE
spec:
  volumeSnapshotClassName: $SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: test-pvc
EOF

  # Wait for snapshot to be ready
  log_info "Waiting for snapshot to be ready..."
  if kubectl wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/test-snapshot -n "$TEST_NAMESPACE" --timeout=180s; then
    log_success "Snapshot created successfully"
    kubectl get volumesnapshot test-snapshot -n "$TEST_NAMESPACE"
  else
    log_error "Snapshot failed to become ready"
    kubectl describe volumesnapshot/test-snapshot -n "$TEST_NAMESPACE"
    exit 1
  fi

  # =============================================================================
  # Test 4: Restore from Snapshot
  # =============================================================================

  log_info "=== Test 4: Restoring PVC from Snapshot ==="

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-restored
  namespace: $TEST_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: test-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

  # Wait for restored PVC to be bound
  log_info "Waiting for restored PVC to be Bound..."
  if kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/test-pvc-restored -n "$TEST_NAMESPACE" --timeout=180s; then
    log_success "Restored PVC is Bound"
  else
    log_error "Restored PVC failed to become Bound"
    kubectl describe pvc/test-pvc-restored -n "$TEST_NAMESPACE"
    exit 1
  fi

  # =============================================================================
  # Test 5: Verify restored data
  # =============================================================================

  log_info "=== Test 5: Verifying restored data ==="

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-reader
  namespace: $TEST_NAMESPACE
spec:
  containers:
    - name: reader
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "Reading restored data..."
          RESTORED_DATA=\$(cat /data/test.txt)
          echo "Restored data: \$RESTORED_DATA"
          if [ "\$RESTORED_DATA" == "$TEST_DATA" ]; then
            echo "SUCCESS: Data matches!"
            exit 0
          else
            echo "FAILURE: Data mismatch!"
            echo "Expected: $TEST_DATA"
            echo "Got: \$RESTORED_DATA"
            exit 1
          fi
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-pvc-restored
  restartPolicy: Never
EOF

  # Wait for reader pod
  log_info "Waiting for reader pod..."
  kubectl wait --for=condition=Ready pod/test-reader -n "$TEST_NAMESPACE" --timeout=120s || true

  # Wait for completion and check result
  sleep 10
  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-reader -n "$TEST_NAMESPACE" --timeout=60s 2>/dev/null; then
    log_success "Data verification passed!"
    kubectl logs test-reader -n "$TEST_NAMESPACE"
  else
    POD_STATUS=$(kubectl get pod/test-reader -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}')
    log_error "Data verification failed. Pod status: $POD_STATUS"
    kubectl logs test-reader -n "$TEST_NAMESPACE" 2>/dev/null || true
    exit 1
  fi
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Storage Test Summary ==="
echo "Provider: $STORAGE_PROVIDER"
echo "StorageClass: $STORAGE_CLASS"
echo "Tests passed:"
echo "  - PVC creation: OK"
echo "  - Data write: OK"
if [ "$SKIP_SNAPSHOT" != "true" ]; then
  echo "  - Snapshot creation: OK"
  echo "  - Snapshot restore: OK"
  echo "  - Data verification: OK"
else
  echo "  - Snapshot tests: SKIPPED"
fi

log_success "All storage tests passed!"
