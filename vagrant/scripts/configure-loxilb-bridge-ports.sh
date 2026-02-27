#!/bin/bash
# configure-loxilb-bridge-ports.sh
#
# Disables unknown-unicast flooding and MAC learning on loxilb VM bridge ports.
#
# Why: When a BGP peer (FRR) VM shuts down, its MAC disappears from the bridge
# FDB. GoBGP on loxilb instances sends TCP SYN (port 179) to the dead peer.
# These SYNs become unknown-unicast and are flooded to ALL bridge ports.
# Each loxilb's eBPF datapath re-forwards these packets (it has a route/neighbor
# entry for the dead peer), creating a feedback loop at 80-100k+ pps that
# saturates TAP queues and drops legitimate traffic on all bridge ports.
#
# Fix: "flood off" prevents unknown-unicast from reaching loxilb ports,
# breaking the feedback loop. Directed unicast (known destination MAC) still
# works. Broadcast (ARP) and multicast are unaffected.
#
# Usage: sudo ./configure-loxilb-bridge-ports.sh <vm-name>
#   e.g.: sudo ./configure-loxilb-bridge-ports.sh k8s-dev-loxilb1

set -euo pipefail

VM_NAME="${1:?Usage: $0 <vm-name>}"

# Get bridge-attached interfaces for this VM
IFACES=$(virsh domiflist "$VM_NAME" 2>/dev/null | awk '/vnet/{print $1}')

if [ -z "$IFACES" ]; then
  echo "No bridge interfaces found for VM '$VM_NAME'" >&2
  exit 0
fi

for iface in $IFACES; do
  bridge link set dev "$iface" flood off 2>/dev/null && \
    echo "  $iface: flood off" || \
    echo "  $iface: failed to configure (interface may not exist)" >&2
done
