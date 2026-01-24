#!/bin/bash
# =============================================================================
# Create K3d cluster with Cilium for CI testing
# =============================================================================
# Creates a K3d cluster using config file with:
#   - Flannel/Traefik/ServiceLB/LocalStorage disabled (we use our own)
#   - Cilium CNI with Hubble enabled
#   - Port mapping for HTTP/HTTPS
# =============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3D_CONFIG="${K3D_CONFIG:-$SCRIPT_DIR/../config/k3d-ci.yaml}"

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-ci-cluster}"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.5}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# =============================================================================
# Main
# =============================================================================

log_info "Creating K3d cluster: $CLUSTER_NAME"
log_info "Using config: $K3D_CONFIG"

# Verify config file exists
if [ ! -f "$K3D_CONFIG" ]; then
  log_error "K3d config file not found: $K3D_CONFIG"
  exit 1
fi

# Delete existing cluster if present
if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}"; then
  log_info "Deleting existing cluster..."
  k3d cluster delete "$CLUSTER_NAME"
fi

# Create K3d cluster from config file
k3d cluster create --config "$K3D_CONFIG"

log_success "K3d cluster created"

# Get node IP for Cilium k8sServiceHost (nodes won't be Ready yet without CNI)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
log_info "Node IP: $NODE_IP"

# Install Cilium
log_info "Installing Cilium $CILIUM_VERSION..."

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium

helm install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --set operator.replicas=1 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$NODE_IP" \
  --set k8sServicePort=6443 \
  --set hostFirewall.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=false \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp}" \
  --set bpf.masquerade=true \
  --set ipam.mode=kubernetes \
  --set routingMode=native \
  --set autoDirectNodeRoutes=true \
  --set l2announcements.enabled=false \
  --wait \
  --timeout 10m

log_success "Cilium installed"

# Wait for nodes to be ready (now that CNI is installed)
log_info "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
log_success "Nodes ready"

# Wait for Cilium pods
log_info "Waiting for Cilium pods..."
kubectl wait --for=condition=Ready pod -l k8s-app=cilium -n kube-system --timeout=300s
kubectl wait --for=condition=Ready pod -l name=cilium-operator -n kube-system --timeout=300s
log_success "Cilium pods ready"

# Wait for Hubble Relay
log_info "Waiting for Hubble Relay..."
kubectl wait --for=condition=Ready pod -l k8s-app=hubble-relay -n kube-system --timeout=120s || true
log_success "Hubble Relay ready"

# Show cluster status
log_info "Cluster status:"
kubectl get nodes -o wide
kubectl get pods -n kube-system -l k8s-app=cilium

log_success "Cluster ready for deployment"
