#!/bin/bash
# =============================================================================
# Start LoxiLB External Container for k3d
# =============================================================================
# Launches a standalone LoxiLB Docker container on the host network (--net=host)
# that acts as the external load balancer for a k3d cluster.
#
# kube-loxilb (running inside the k3d cluster) connects to this container
# via --loxiURL=http://<host-ip>:11111 to configure load balancer rules.
#
# Usage:
#   ./start-loxilb-external.sh              # Start with defaults
#   ./start-loxilb-external.sh --stop       # Stop and remove the container
#   ./start-loxilb-external.sh --status     # Check container status
#
# Environment variables:
#   LOXILB_IMAGE    - LoxiLB image (default: ghcr.io/loxilb-io/loxilb:latest)
#   LOXILB_NAME     - Container name (default: loxilb-external)
# =============================================================================

set -euo pipefail

LOXILB_IMAGE="${LOXILB_IMAGE:-ghcr.io/loxilb-io/loxilb:latest}"
LOXILB_NAME="${LOXILB_NAME:-loxilb-external}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*"; }

stop_container() {
  if docker ps -a --format '{{.Names}}' | grep -q "^${LOXILB_NAME}$"; then
    log_info "Stopping and removing container ${LOXILB_NAME}..."
    docker rm -f "${LOXILB_NAME}" >/dev/null 2>&1
    log_success "Container ${LOXILB_NAME} removed"
  else
    log_info "Container ${LOXILB_NAME} not found"
  fi
}

show_status() {
  if docker ps --format '{{.Names}}' | grep -q "^${LOXILB_NAME}$"; then
    log_success "Container ${LOXILB_NAME} is running"
    echo ""
    echo "Container details:"
    docker inspect "${LOXILB_NAME}" --format '  Image: {{.Config.Image}}'
    docker inspect "${LOXILB_NAME}" --format '  Status: {{.State.Status}}'
    docker inspect "${LOXILB_NAME}" --format '  Network: host'
    echo ""
    echo "API endpoint: http://$(hostname -I | awk '{print $1}'):11111"
    echo ""
    echo "Testing API..."
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all" | grep -q "200"; then
      log_success "LoxiLB API is responding"
    else
      log_warning "LoxiLB API is not responding yet (may still be starting)"
    fi
  else
    log_warning "Container ${LOXILB_NAME} is not running"
  fi
}

start_container() {
  # Check if already running
  if docker ps --format '{{.Names}}' | grep -q "^${LOXILB_NAME}$"; then
    log_warning "Container ${LOXILB_NAME} is already running"
    show_status
    return 0
  fi

  # Remove stopped container if exists
  if docker ps -a --format '{{.Names}}' | grep -q "^${LOXILB_NAME}$"; then
    log_info "Removing stopped container ${LOXILB_NAME}..."
    docker rm "${LOXILB_NAME}" >/dev/null 2>&1
  fi

  log_info "Starting LoxiLB external container..."
  log_info "  Image: ${LOXILB_IMAGE}"
  log_info "  Name: ${LOXILB_NAME}"
  log_info "  Network: host (--net=host)"

  docker run -u root \
    --cap-add SYS_ADMIN \
    --restart unless-stopped \
    --privileged \
    -dit \
    --name "${LOXILB_NAME}" \
    --net=host \
    "${LOXILB_IMAGE}"

  log_success "Container ${LOXILB_NAME} started"
  echo ""

  # Wait for API to be ready
  log_info "Waiting for LoxiLB API to be ready..."
  local retries=0
  local max_retries=30
  while [ $retries -lt $max_retries ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all" 2>/dev/null | grep -q "200"; then
      log_success "LoxiLB API is ready at http://127.0.0.1:11111"
      echo ""
      echo "Configure kube-loxilb with:"
      echo "  --loxiURL=http://$(hostname -I | awk '{print $1}'):11111"
      return 0
    fi
    retries=$((retries + 1))
    sleep 2
  done

  log_warning "LoxiLB API did not become ready within ${max_retries} retries"
  log_warning "Check container logs: docker logs ${LOXILB_NAME}"
}

# Parse arguments
case "${1:-}" in
  --stop|-s)
    stop_container
    ;;
  --status|-S)
    show_status
    ;;
  --help|-h)
    echo "Usage: $0 [--stop|--status|--help]"
    echo ""
    echo "Start a LoxiLB external container for k3d clusters."
    echo ""
    echo "Options:"
    echo "  --stop, -s     Stop and remove the container"
    echo "  --status, -S   Show container status"
    echo "  --help, -h     Show this help"
    echo ""
    echo "Environment variables:"
    echo "  LOXILB_IMAGE   LoxiLB image (default: ghcr.io/loxilb-io/loxilb:latest)"
    echo "  LOXILB_NAME    Container name (default: loxilb-external)"
    ;;
  *)
    start_container
    ;;
esac
