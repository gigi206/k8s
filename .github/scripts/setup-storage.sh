#!/bin/bash
# =============================================================================
# Setup storage for Longhorn/Rook in CI environment
# =============================================================================
# Prepares the host for storage providers:
#   - Longhorn: Installs open-iscsi, creates data directory
#   - Rook: Creates loop device from file image for Ceph OSD
# =============================================================================

set -euo pipefail

STORAGE_PROVIDER="${STORAGE_PROVIDER:-none}"
LOOP_DEVICE_SIZE_MB="${LOOP_DEVICE_SIZE_MB:-10240}"  # 10GB default
LOOP_FILE="${LOOP_FILE:-/tmp/ceph-osd.img}"

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

log_info "Setting up storage for provider: $STORAGE_PROVIDER"

case "$STORAGE_PROVIDER" in
  longhorn)
    log_info "Installing open-iscsi for Longhorn..."

    # Install open-iscsi (required by Longhorn for iSCSI support)
    sudo apt-get update
    sudo apt-get install -y open-iscsi

    # Enable and start iscsid
    sudo systemctl enable --now iscsid

    # Verify iscsid is running
    if sudo systemctl is-active --quiet iscsid; then
      log_success "iscsid is running"
    else
      log_error "Failed to start iscsid"
      exit 1
    fi

    # Create Longhorn data directory
    sudo mkdir -p /var/lib/longhorn
    log_success "Longhorn data directory created: /var/lib/longhorn"

    # Show available disk space
    log_info "Available disk space:"
    df -h /var/lib/longhorn
    ;;

  rook)
    log_info "Creating loop device for Rook/Ceph OSD..."

    # Check if we have enough space
    AVAILABLE_MB=$(df -m /tmp | awk 'NR==2 {print $4}')
    if [ "$AVAILABLE_MB" -lt "$LOOP_DEVICE_SIZE_MB" ]; then
      log_error "Not enough space in /tmp. Available: ${AVAILABLE_MB}MB, Required: ${LOOP_DEVICE_SIZE_MB}MB"
      exit 1
    fi

    # Create the image file
    log_info "Creating ${LOOP_DEVICE_SIZE_MB}MB image file..."
    sudo dd if=/dev/zero of="$LOOP_FILE" bs=1M count="$LOOP_DEVICE_SIZE_MB" status=progress

    # Associate with a loop device
    LOOP_DEV=$(sudo losetup --find --show "$LOOP_FILE")
    log_success "Loop device created: $LOOP_DEV"

    # Export for the workflow
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "rook_osd_device=$LOOP_DEV" >> "$GITHUB_OUTPUT"
      echo "loop_file=$LOOP_FILE" >> "$GITHUB_OUTPUT"
    fi

    # Also export as environment variable for current shell
    export ROOK_OSD_DEVICE="$LOOP_DEV"

    # Create Rook data directory
    sudo mkdir -p /var/lib/rook
    log_success "Rook data directory created: /var/lib/rook"

    # Show loop device info
    log_info "Loop device info:"
    sudo losetup -l "$LOOP_DEV"
    ;;

  none|"")
    log_info "No storage provider specified, skipping setup"
    ;;

  *)
    log_error "Unknown storage provider: $STORAGE_PROVIDER"
    log_info "Supported providers: longhorn, rook, none"
    exit 1
    ;;
esac

log_success "Storage setup complete"
