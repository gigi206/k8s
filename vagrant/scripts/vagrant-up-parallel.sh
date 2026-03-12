#!/bin/bash
# =============================================================================
# Parallel Vagrant Up
# =============================================================================
# Launches VMs in phases to maximize parallelism while respecting dependencies:
#   Phase 1: LB infra (loxilb + frr) — sequential (NFS export race with parallel)
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

# Run vagrant up for a list of VMs
# Usage: up_vms [--sequential] <phase_name> <vm1> [vm2 ...]
#   --sequential: start VMs one at a time (avoids NFS race conditions)
#   default: parallel when multiple VMs
up_vms() {
  local sequential=false
  if [ "$1" = "--sequential" ]; then
    sequential=true
    shift
  fi

  local phase_name="$1"
  shift
  local vms=("$@")

  if [ ${#vms[@]} -eq 0 ]; then
    return 0
  fi

  echo -e "${BLUE}  Phase: ${phase_name} (${#vms[@]} VM(s): ${vms[*]})${NC}"

  if [ ${#vms[@]} -eq 1 ] || [ "$sequential" = true ]; then
    for vm in "${vms[@]}"; do
      vagrant_cmd up "$vm" --no-parallel
    done
  else
    vagrant_cmd up "${vms[@]}" --parallel
  fi
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Parallel Vagrant Up (env: ${ENV})${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CLUSTER_NAME="$ENV"
PREFIX="k8s-${CLUSTER_NAME}-"

# --- Pre-flight: clean orphan libvirt resources ---
orphan_domains=$(virsh list --all --name 2>/dev/null | grep "^${PREFIX}" || true)
orphan_volumes=$(virsh vol-list default 2>/dev/null | awk 'NR>2 && /'"${PREFIX}"'/ {print $1}' || true)

if [ -n "$orphan_domains" ] || [ -n "$orphan_volumes" ]; then
  echo -e "${YELLOW}  Pre-flight: orphan libvirt resources detected, cleaning...${NC}"
  for domain in $orphan_domains; do
    if virsh domstate "$domain" 2>/dev/null | grep -q "running"; then
      virsh destroy "$domain" 2>/dev/null || true
    fi
    virsh undefine "$domain" --remove-all-storage --nvram 2>/dev/null || \
      virsh undefine "$domain" --remove-all-storage 2>/dev/null || \
      virsh undefine "$domain" 2>/dev/null || true
    echo -e "    Removed domain: $domain"
  done
  for vol in $orphan_volumes; do
    virsh vol-delete "$vol" --pool default 2>/dev/null || true
    echo -e "    Removed volume: $vol"
  done
  # Clean stale .vagrant/machines state
  if [ -d ".vagrant/machines" ]; then
    for machine_dir in .vagrant/machines/${PREFIX}*/; do
      [ -d "$machine_dir" ] && rm -rf "$machine_dir" && echo -e "    Removed state: $(basename "$machine_dir")"
    done
  fi
  echo -e "${GREEN}  Pre-flight cleanup done${NC}"
  echo ""
fi

# --- Pre-flight: ensure vagrant-libvirt network exists and is active ---
if ! virsh net-info vagrant-libvirt &>/dev/null; then
  echo -e "${YELLOW}  Pre-flight: vagrant-libvirt network missing, creating...${NC}"
  virsh net-define /dev/stdin <<'NETXML'
<network>
  <name>vagrant-libvirt</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.121.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.121.100' end='192.168.121.254'/>
    </dhcp>
  </ip>
</network>
NETXML
fi
if ! virsh net-info vagrant-libvirt 2>/dev/null | grep -q "Actif.*oui\|Active.*yes"; then
  virsh net-start vagrant-libvirt
  echo -e "${GREEN}  vagrant-libvirt network started${NC}"
fi
virsh net-autostart vagrant-libvirt &>/dev/null

# Discover VMs by role
LOXILB_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-loxilb"))
FRR_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-frr"))
MASTER_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-m[0-9]"))
WORKER_VMS=($(get_vms "^k8s-${CLUSTER_NAME}-w[0-9]"))

INFRA_VMS=("${LOXILB_VMS[@]}" "${FRR_VMS[@]}")
TOTAL=$((${#INFRA_VMS[@]} + ${#MASTER_VMS[@]} + ${#WORKER_VMS[@]}))

echo -e "${GREEN}  Discovered: ${#LOXILB_VMS[@]} loxilb, ${#FRR_VMS[@]} frr, ${#MASTER_VMS[@]} master(s), ${#WORKER_VMS[@]} worker(s)${NC}"
echo ""

# --- Phase 1: LB infrastructure (loxilb + frr, sequential to avoid NFS race) ---
if [ ${#INFRA_VMS[@]} -gt 0 ]; then
  up_vms --sequential "LB infrastructure (loxilb + frr)" "${INFRA_VMS[@]}"
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
