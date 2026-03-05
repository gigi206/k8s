#!/bin/bash
# =============================================================================
# Robust Vagrant Destroy with libvirt fallback
# =============================================================================
# Attempts `vagrant destroy -f` first, then falls back to virsh cleanup
# for orphaned domains, volumes, and stale vagrant machine state.
#
# Usage: vagrant-destroy-clean.sh <env> [VAGRANT_VARS...]
# Example: vagrant-destroy-clean.sh dev CNI_PRIMARY=cilium LB_PROVIDER=loxilb
# =============================================================================

set -eo pipefail

ENV="${1:?Usage: $0 <env> [VAGRANT_VARS...]}"
shift

# Export K8S_ENV and all KEY=VALUE pairs as environment variables for vagrant
export K8S_ENV="$ENV"
for arg in "$@"; do
  export "$arg"
done

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAGRANT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="k8s-${ENV}-"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Robust Vagrant Destroy (env: ${ENV})${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

cleaned_domains=()
cleaned_volumes=()
cleaned_machines=()

# --- Step 1: Try vagrant destroy -f ---
echo -e "${BLUE}  Step 1: vagrant destroy -f${NC}"
cd "$VAGRANT_DIR"
if vagrant destroy -f 2>/dev/null; then
  echo -e "${GREEN}  vagrant destroy succeeded${NC}"
else
  echo -e "${YELLOW}  vagrant destroy failed, falling back to virsh cleanup${NC}"

  # --- Step 2: Force stop and undefine domains ---
  echo -e "${BLUE}  Step 2: virsh domain cleanup${NC}"
  for domain in $(virsh list --all --name 2>/dev/null | grep "^${PREFIX}" || true); do
    # Force stop (safe on already-stopped domains)
    virsh destroy "$domain" 2>/dev/null || true
    # Undefine with storage removal
    virsh undefine "$domain" --remove-all-storage --nvram 2>/dev/null || \
      virsh undefine "$domain" --remove-all-storage 2>/dev/null || \
      virsh undefine "$domain" 2>/dev/null || true
    cleaned_domains+=("$domain")
  done
fi

# --- Step 3: Clean orphan volumes in default pool ---
echo -e "${BLUE}  Step 3: orphan volume cleanup${NC}"
for vol in $(virsh vol-list default 2>/dev/null | awk 'NR>2 && /'"${PREFIX}"'/ {print $1}' || true); do
  virsh vol-delete "$vol" --pool default 2>/dev/null || true
  cleaned_volumes+=("$vol")
done

# --- Step 4: Clean stale .vagrant/machines state ---
echo -e "${BLUE}  Step 4: stale vagrant machine state cleanup${NC}"
if [ -d "$VAGRANT_DIR/.vagrant/machines" ]; then
  for machine_dir in "$VAGRANT_DIR/.vagrant/machines/${PREFIX}"*/; do
    if [ -d "$machine_dir" ]; then
      machine_name=$(basename "$machine_dir")
      rm -rf "$machine_dir"
      cleaned_machines+=("$machine_name")
    fi
  done
fi

# --- Summary ---
echo ""
echo -e "${GREEN}  Cleanup summary (env: ${ENV}):${NC}"
if [ ${#cleaned_domains[@]} -gt 0 ]; then
  echo -e "    Domains removed:  ${cleaned_domains[*]}"
fi
if [ ${#cleaned_volumes[@]} -gt 0 ]; then
  echo -e "    Volumes removed:  ${cleaned_volumes[*]}"
fi
if [ ${#cleaned_machines[@]} -gt 0 ]; then
  echo -e "    Machine dirs removed: ${cleaned_machines[*]}"
fi
if [ ${#cleaned_domains[@]} -eq 0 ] && [ ${#cleaned_volumes[@]} -eq 0 ] && [ ${#cleaned_machines[@]} -eq 0 ]; then
  echo -e "    Nothing extra to clean"
fi
echo -e "${GREEN}  Done.${NC}"
