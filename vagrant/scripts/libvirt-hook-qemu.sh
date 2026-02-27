#!/bin/bash
# libvirt qemu hook — applies bridge port settings when loxilb VMs start
#
# Install: sudo cp this /etc/libvirt/hooks/qemu && sudo chmod +x /etc/libvirt/hooks/qemu
#          sudo systemctl restart libvirtd
#
# libvirt calls: /etc/libvirt/hooks/qemu <guest_name> <operation> <sub-operation>
# We act on "started" to configure bridge ports after the VM is fully running.

GUEST_NAME="$1"
OPERATION="$2"

# Only act on loxilb VMs at startup
if [[ "$GUEST_NAME" == *-loxilb* && "$OPERATION" == "started" ]]; then
  for iface in $(virsh domiflist "$GUEST_NAME" 2>/dev/null | awk '/vnet/{print $1}'); do
    bridge link set dev "$iface" flood off 2>/dev/null
  done
fi
