#!/bin/bash
# configure-loxilb-bridge-ports.sh
#
# Secures bridge ports for loxilb VMs to prevent MAC flapping and eBPF
# feedback loops that break connectivity to other VMs (notably the master).
#
# Problem 1 (BGP mode): When a BGP peer VM shuts down, GoBGP sends TCP SYN
# (port 179) to the dead peer. These become unknown-unicast, are flooded to
# all bridge ports, and each loxilb's eBPF re-forwards them — creating a
# feedback loop at 80-100k+ pps that saturates TAP queues.
#
# Problem 2 (ALL modes): kube-vip sends GARP broadcasts for the K8s API VIP
# using the master's eth1 MAC. These broadcasts reach loxilb VMs, whose eBPF
# datapath reflects them back onto the bridge with the master's source MAC.
# The bridge re-learns the master's MAC on a loxilb port, directing all
# traffic for the master's eth1 to the wrong VM — breaking K8s API access.
#
# Fix:
#   flood off    — prevents unknown-unicast flooding to loxilb ports (Problem 1)
#   learning off — prevents the bridge from learning MACs from loxilb-reflected
#                  frames, so the master's MAC stays on its correct port (Problem 2)
#
# With learning off, static FDB entries are added for the loxilb VM's own MACs
# so directed unicast still reaches the correct loxilb port.
#
# Usage: sudo ./configure-loxilb-bridge-ports.sh <vm-name>
#   e.g.: sudo ./configure-loxilb-bridge-ports.sh k8s-dev-loxilb1

set -euo pipefail

# Re-exec as root if not already (Vagrant trigger.run doesn't support sudo)
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then
    exec sudo "$0" "$@"
  else
    echo -e "\033[1;5;33mWARNING: No passwordless sudo available. Run manually:\033[0m" >&2
    echo -e "\033[1;33m  sudo $0 $*\033[0m" >&2
    exit 0
  fi
fi

VM_NAME="${1:?Usage: $0 <vm-name>}"

# Get bridge-attached interfaces and their MACs for this VM
# Format from virsh: "vnetX  network  vagrant-libvirt  virtio  52:54:00:xx:xx:xx"
IFACE_INFO=$(virsh domiflist "$VM_NAME" 2>/dev/null | awk '/vnet/{print $1, $5}')

if [ -z "$IFACE_INFO" ]; then
  echo "No bridge interfaces found for VM '$VM_NAME'" >&2
  exit 0
fi

while read -r iface mac; do
  # Disable flooding (unknown-unicast) and learning (prevents MAC flapping)
  if bridge link set dev "$iface" flood off learning off 2>/dev/null; then
    echo "  $iface: flood off, learning off"
  else
    echo "  $iface: failed to configure (interface may not exist)" >&2
    continue
  fi

  # Add static FDB entry so the loxilb VM can still receive directed unicast
  # on its own MAC address (required since learning is disabled)
  if [ -n "$mac" ]; then
    bridge fdb replace "$mac" dev "$iface" master static 2>/dev/null && \
      echo "  $iface: static FDB $mac" || \
      echo "  $iface: failed to add static FDB for $mac" >&2
  fi
done <<< "$IFACE_INFO"
