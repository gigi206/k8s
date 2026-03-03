#!/bin/bash
# =============================================================================
# Parallel Vagrant Up
# =============================================================================
# Launches VMs in phases to maximize parallelism while respecting dependencies:
#   Phase 1: LB infra (loxilb + frr) — no dependencies, fully parallel
#   Phase 2: master1 — initializes cluster, must run alone
#   Phase 3: remaining masters + workers — wait for k8s-token from master1
#
# Usage: vagrant-up-parallel.sh <env> [VAGRANT_VARS...]
# Example: vagrant-up-parallel.sh dev CNI_PRIMARY=cilium LB_PROVIDER=loxilb LB_MODE=bgp
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
NC='\033[0m'

cd "$(dirname "$0")/.."

vagrant_cmd() {
  vagrant "$@"
}

# Get list of defined VMs matching a regex pattern
get_vms() {
  local pattern="$1"
  vagrant_cmd status --machine-readable 2>/dev/null | \
    awk -F',' '$3 == "state" { print $2 }' | \
    grep -E "$pattern" || true
}

# Run vagrant up for a list of VMs (parallel if multiple)
up_vms() {
  local phase_name="$1"
  shift
  local vms=("$@")

  if [ ${#vms[@]} -eq 0 ]; then
    return 0
  fi

  echo -e "${BLUE}  Phase: ${phase_name} (${#vms[@]} VM(s): ${vms[*]})${NC}"

  if [ ${#vms[@]} -eq 1 ]; then
    vagrant_cmd up "${vms[0]}" --no-parallel
  else
    vagrant_cmd up "${vms[@]}" --parallel
  fi
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Parallel Vagrant Up (env: ${ENV})${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CLUSTER_NAME="$ENV"

# Discover VMs by role
LOXILB_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-loxilb"))
FRR_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-frr"))
MASTER_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-m[0-9]"))
WORKER_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-w[0-9]"))

INFRA_VMS=("${LOXILB_VMS[@]}" "${FRR_VMS[@]}")
TOTAL=$((${#INFRA_VMS[@]} + ${#MASTER_VMS[@]} + ${#WORKER_VMS[@]}))

echo -e "${GREEN}  Discovered: ${#LOXILB_VMS[@]} loxilb, ${#FRR_VMS[@]} frr, ${#MASTER_VMS[@]} master(s), ${#WORKER_VMS[@]} worker(s)${NC}"
echo ""

# --- Phase 1: LB infrastructure (loxilb + frr in parallel) ---
if [ ${#INFRA_VMS[@]} -gt 0 ]; then
  up_vms "LB infrastructure (loxilb + frr)" "${INFRA_VMS[@]}"
  echo ""
fi

# --- Phase 2: master1 (initializes cluster) ---
if [ ${#MASTER_VMS[@]} -gt 0 ]; then
  up_vms "master1 (cluster init)" "${MASTER_VMS[0]}"
  echo ""
fi

# --- Phase 3: remaining masters + workers (parallel) ---
REMAINING_VMS=("${MASTER_VMS[@]:1}" "${WORKER_VMS[@]}")
if [ ${#REMAINING_VMS[@]} -gt 0 ]; then
  up_vms "remaining masters + workers" "${REMAINING_VMS[@]}"
  echo ""
fi

echo -e "${GREEN}  All ${TOTAL} VM(s) started.${NC}"
