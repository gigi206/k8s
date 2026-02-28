#!/usr/bin/env bash
# =============================================================================
# Provision FRR BGP Upstream Router inside dedicated Vagrant VM
# =============================================================================
# Runs on a separate VM (k8s-<cluster>-frr) to simulate a physical BGP router
# upstream of the cluster in pure BGP mode (loadBalancer.mode: bgp).
#
# Topology depends on LB provider:
#   loxilb:  loxilb (65002) <-eBGP-> FRR (65000) <-eBGP-> Cilium (64512)
#   metallb: metallb-speaker (64512) <-eBGP-> FRR (65000)
#   cilium:  cilium bgpControlPlane (64512) <-eBGP-> FRR (65000)
#
# FRR acts as a route reflector / ECMP upstream router:
#   - Learns VIP /32 routes from loxilb (loxilb mode) or LB provider via eBGP
#   - Learns PodCIDR routes from Cilium via eBGP
#   - Proxy-ARP on eth1: responds to ARP for VIPs -> forwards to LB provider
#   - ip_forward: routes packets between LB provider and cluster nodes
#
# Called conditionally by Vagrantfile when:
#   LB_MODE=bgp and LB_PROVIDER != klipper
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Network interface used for BGP peering and VRRP
FRR_IFACE="${FRR_IFACE:-eth1}"

# Determine project root (NFS mount at /vagrant)
if [ -f "/vagrant/vagrant/scripts/RKE2_ENV.sh" ]; then
  PROJECT_ROOT="/vagrant"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi

K8S_ENV="${K8S_ENV:-dev}"

ARGOCD_CONFIG="$PROJECT_ROOT/deploy/argocd/config/config.yaml"
LOXILB_APP_CONFIG="$PROJECT_ROOT/deploy/argocd/apps/loxilb/config/${K8S_ENV}.yaml"

# Verify files exist
if [ ! -f "$ARGOCD_CONFIG" ]; then
  echo "[WARN] Config not found: $ARGOCD_CONFIG"
  exit 0
fi

# Check if LB mode is bgp
LB_MODE=$(yq '.features.loadBalancer.mode // "l2"' "$ARGOCD_CONFIG" 2>/dev/null || echo "l2")
if [[ "$LB_MODE" != "bgp" ]]; then
  echo "[INFO] loadBalancer.mode=$LB_MODE (not bgp), FRR provisioning skipped."
  exit 0
fi

# Detect LB provider to determine FRR peering topology
LB_PROVIDER=$(yq '.features.loadBalancer.provider // "metallb"' "$ARGOCD_CONFIG" 2>/dev/null || echo "metallb")

# FRR ASN: this VM's own ASN = peers[0].asn (FRR is peers[0] from the cluster's perspective)
FRR_ASN=$(yq '.features.loadBalancer.bgp.peers[0].asn // 65000' "$ARGOCD_CONFIG" 2>/dev/null || echo "65000")
# Cluster ASN: the local ASN used by the LB provider (metallb speakers / cilium bgpControlPlane)
CLUSTER_ASN=$(yq '.features.loadBalancer.bgp.localASN // 64512' "$ARGOCD_CONFIG" 2>/dev/null || echo "64512")

# VRRP configuration
VRRP_ENABLED=$(yq '.features.loadBalancer.bgp.vrrp.enabled // false' "$ARGOCD_CONFIG" 2>/dev/null || echo "false")
VRRP_VIP=$(yq '.features.loadBalancer.bgp.vrrp.vip // ""' "$ARGOCD_CONFIG" 2>/dev/null || echo "")
VRRP_VRID=$(yq '.features.loadBalancer.bgp.vrrp.vrid // 1' "$ARGOCD_CONFIG" 2>/dev/null || echo "1")
VRRP_ADV_INTERVAL=$(yq '.features.loadBalancer.bgp.vrrp.advertisementInterval // 100' "$ARGOCD_CONFIG" 2>/dev/null || echo "100")
VRRP_PRIORITY=50  # default: backup

# Determine FRR_IFACE IP (this VM: .45), master IP (.50)
ETH1_IP=$(ip -4 addr show "$FRR_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
if [ -z "$ETH1_IP" ]; then
  echo "[WARN] $FRR_IFACE has no IPv4 address yet, using configured peer address"
  ETH1_IP=$(yq '.features.loadBalancer.bgp.peers[0].address // "192.168.121.45"' "$ARGOCD_CONFIG" 2>/dev/null || echo "192.168.121.45")
fi
# Derive master IP by replacing last octet with 50
NETWORK_PREFIX=$(echo "$ETH1_IP" | cut -d. -f1-3)
MASTER_IP="${NETWORK_PREFIX}.50"

# Calculate VRRP priority: index 0 in peers[] = priority 100 (master), index 1 = priority 50 (backup)
if [[ "$VRRP_ENABLED" == "true" ]]; then
  PEER_COUNT=$(yq '.features.loadBalancer.bgp.peers | length' "$ARGOCD_CONFIG" 2>/dev/null || echo "0")
  for ((i=0; i<PEER_COUNT; i++)); do
    PEER_IP=$(yq ".features.loadBalancer.bgp.peers[$i].address" "$ARGOCD_CONFIG" 2>/dev/null || echo "")
    if [[ "$PEER_IP" == "$ETH1_IP" ]]; then
      VRRP_PRIORITY=$((100 - i * 50))
      break
    fi
  done
fi

echo "[INFO] FRR BGP router provisioning (mode: bgp, provider: $LB_PROVIDER)"
echo "[INFO]   FRR IP:       $ETH1_IP ($FRR_IFACE)"
echo "[INFO]   FRR ASN:      $FRR_ASN"
echo "[INFO]   Cluster ASN:  $CLUSTER_ASN"
echo "[INFO]   Master IP:    $MASTER_IP"
if [[ "$VRRP_ENABLED" == "true" ]]; then
  echo "[INFO]   VRRP:         enabled (VIP=$VRRP_VIP, VRID=$VRRP_VRID, priority=$VRRP_PRIORITY)"
fi

# =============================================================================
# Install FRR
# =============================================================================
if ! command -v vtysh &>/dev/null; then
  echo "[INFO] Installing FRR..."
  apt-get update -qq
  apt-get install -y frr frr-pythontools
  echo "[OK] FRR installed"
else
  echo "[OK] FRR already installed"
fi

# =============================================================================
# Enable bgpd daemon
# =============================================================================
echo "[INFO] Enabling bgpd in /etc/frr/daemons..."
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
if [[ "$VRRP_ENABLED" == "true" ]]; then
  echo "[INFO] Enabling vrrpd in /etc/frr/daemons..."
  sed -i 's/^vrrpd=no/vrrpd=yes/' /etc/frr/daemons
fi
grep "^bgpd=" /etc/frr/daemons

# =============================================================================
# Create VRRP macvlan interface (before frr.conf generation)
# =============================================================================
# FRR vrrpd uses a macvlan interface with the VRRP virtual MAC.
# Pre-create it for reliability (FRR auto-creates but manual is more robust).
if [[ "$VRRP_ENABLED" == "true" && -n "$VRRP_VIP" ]]; then
  VRRP_MAC=$(printf '00:00:5e:00:01:%02x' "$VRRP_VRID")
  FRR_IFINDEX=$(cat /sys/class/net/"$FRR_IFACE"/ifindex 2>/dev/null || echo "2")
  VRRP_MACVLAN="vrrp4-${FRR_IFINDEX}-${VRRP_VRID}"

  echo "[INFO] Creating VRRP macvlan interface $VRRP_MACVLAN (MAC=$VRRP_MAC, VIP=$VRRP_VIP)..."
  ip link del "$VRRP_MACVLAN" 2>/dev/null || true
  ip link add "$VRRP_MACVLAN" link "$FRR_IFACE" type macvlan mode bridge
  ip link set dev "$VRRP_MACVLAN" address "$VRRP_MAC"
  ip addr add "${VRRP_VIP}/24" dev "$VRRP_MACVLAN"
  ip link set dev "$VRRP_MACVLAN" up
  echo "[OK] VRRP macvlan $VRRP_MACVLAN created"

  # Persist macvlan across reboots via networkd-dispatcher
  cat > /etc/networkd-dispatcher/routable.d/50-vrrp-macvlan.sh << MACVLAN_EOF
#!/bin/bash
if [[ "\$IFACE" == "${FRR_IFACE}" ]]; then
  ip link del ${VRRP_MACVLAN} 2>/dev/null || true
  ip link add ${VRRP_MACVLAN} link ${FRR_IFACE} type macvlan mode bridge
  ip link set dev ${VRRP_MACVLAN} address ${VRRP_MAC}
  ip addr add ${VRRP_VIP}/24 dev ${VRRP_MACVLAN}
  ip link set dev ${VRRP_MACVLAN} up
fi
MACVLAN_EOF
  chmod +x /etc/networkd-dispatcher/routable.d/50-vrrp-macvlan.sh
  echo "[OK] VRRP macvlan persistence script installed"
fi

# =============================================================================
# Generate /etc/frr/frr.conf (topology depends on LB provider)
# =============================================================================
echo "[INFO] Writing /etc/frr/frr.conf (provider: $LB_PROVIDER)..."

if [ "$LB_PROVIDER" = "loxilb" ]; then
  # loxilb mode: FRR peers with both loxilb (for VIP /32 routes) and master (for PodCIDR routes)
  # Topology: loxilb (LOXILB_ASN) <-eBGP-> FRR (FRR_ASN) <-eBGP-> Cilium (CLUSTER_ASN)
  if [ ! -f "$LOXILB_APP_CONFIG" ]; then
    echo "[WARN] LoxiLB config not found: $LOXILB_APP_CONFIG"
    exit 1
  fi
  LOXILB_ASN=$(yq '.loxilb.bgp.localASN' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "65002")
  # loxiURL is a list — read all entries and extract IPs
  mapfile -t LOXILB_URLS < <(yq -r '.loxilb.loxiURL[]' "$LOXILB_APP_CONFIG" 2>/dev/null)
  [ ${#LOXILB_URLS[@]} -eq 0 ] && LOXILB_URLS=("http://192.168.121.40:11111")
  LOXILB_IPS=()
  for url in "${LOXILB_URLS[@]}"; do
    LOXILB_IPS+=("$(echo "$url" | sed 's|https\?://\([0-9.]*\):.*|\1|')")
  done
  echo "[INFO]   LoxiLB IPs:   ${LOXILB_IPS[*]} (ASN $LOXILB_ASN)"

  # Build neighbor declaration and activation blocks for frr.conf
  NEIGHBOR_DECL=""
  NEIGHBOR_ACTIVATE=""
  for i in "${!LOXILB_IPS[@]}"; do
    lox_ip="${LOXILB_IPS[$i]}"
    NEIGHBOR_DECL+=" neighbor ${lox_ip} remote-as ${LOXILB_ASN}
 neighbor ${lox_ip} description loxilb-external-$((i+1))
 neighbor ${lox_ip} ebgp-multihop 2
 neighbor ${lox_ip} timers 3 9
 !
"
    NEIGHBOR_ACTIVATE+="  neighbor ${lox_ip} activate
  neighbor ${lox_ip} soft-reconfiguration inbound
"
  done
  ECMP_PATHS=$(( ${#LOXILB_IPS[@]} + 1 ))

  cat > /etc/frr/frr.conf << EOF
frr version 8.1
frr defaults traditional
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config

router bgp ${FRR_ASN}
 bgp router-id ${ETH1_IP}
 no bgp ebgp-requires-policy
 no bgp network import-check
 !
${NEIGHBOR_DECL} neighbor ${MASTER_IP} remote-as ${CLUSTER_ASN}
 neighbor ${MASTER_IP} description cilium-master
 neighbor ${MASTER_IP} ebgp-multihop 2
 neighbor ${MASTER_IP} timers 60 300
 !
 address-family ipv4 unicast
${NEIGHBOR_ACTIVATE}  neighbor ${MASTER_IP} activate
  neighbor ${MASTER_IP} soft-reconfiguration inbound
  maximum-paths ${ECMP_PATHS}
 exit-address-family
!
line vty
!
EOF
else
  # metallb / cilium mode: FRR peers only with the master node
  # metallb-speaker and cilium bgpControlPlane both run on the master and peer from its IP
  # Topology: LB provider (CLUSTER_ASN, master .50) <-eBGP-> FRR (FRR_ASN)
  echo "[INFO]   Mode: $LB_PROVIDER (single peer: master node $MASTER_IP ASN $CLUSTER_ASN)"

  cat > /etc/frr/frr.conf << EOF
frr version 8.1
frr defaults traditional
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config

router bgp ${FRR_ASN}
 bgp router-id ${ETH1_IP}
 no bgp ebgp-requires-policy
 no bgp network import-check
 !
 neighbor ${MASTER_IP} remote-as ${CLUSTER_ASN}
 neighbor ${MASTER_IP} description ${LB_PROVIDER}-master
 neighbor ${MASTER_IP} ebgp-multihop 2
 neighbor ${MASTER_IP} timers 60 300
 !
 address-family ipv4 unicast
  neighbor ${MASTER_IP} activate
  neighbor ${MASTER_IP} soft-reconfiguration inbound
  maximum-paths 2
 exit-address-family
!
line vty
!
EOF
fi

echo "[OK] /etc/frr/frr.conf written"

# =============================================================================
# Append VRRP configuration to frr.conf
# =============================================================================
if [[ "$VRRP_ENABLED" == "true" && -n "$VRRP_VIP" ]]; then
  echo "[INFO] Appending VRRP config to /etc/frr/frr.conf (VRID=$VRRP_VRID, priority=$VRRP_PRIORITY)..."
  cat >> /etc/frr/frr.conf << VRRP_EOF

interface ${FRR_IFACE}
 vrrp ${VRRP_VRID} version 3
 vrrp ${VRRP_VRID} priority ${VRRP_PRIORITY}
 vrrp ${VRRP_VRID} advertisement-interval ${VRRP_ADV_INTERVAL}
 vrrp ${VRRP_VRID} ip ${VRRP_VIP}
!
VRRP_EOF
  echo "[OK] VRRP config appended"
fi

# =============================================================================
# Sysctl: ip_forward + proxy_arp on FRR_IFACE
# =============================================================================
echo "[INFO] Setting sysctl (ip_forward + proxy_arp on $FRR_IFACE)..."
cat > /etc/sysctl.d/99-frr-routing.conf << EOF
# FRR BGP upstream router - IP forwarding and proxy-ARP for VIPs
net.ipv4.ip_forward = 1
net.ipv4.conf.${FRR_IFACE}.proxy_arp = 1
# ECMP L4 hash: use src/dst ports in addition to src/dst IP for multipath
# routing decisions. Without this (policy=0), all traffic from the same
# source IP to the same VIP is sent to a single nexthop. With policy=1,
# different connections (different src ports) are distributed across all
# ECMP nexthops, limiting the impact of a failed LB instance to ~1/N
# instead of 100%.
net.ipv4.fib_multipath_hash_policy = 1
EOF
if [[ "$VRRP_ENABLED" == "true" ]]; then
  cat >> /etc/sysctl.d/99-frr-routing.conf << EOF
# VRRP: accept gratuitous ARP for fast failover
net.ipv4.conf.${FRR_IFACE}.arp_accept = 1
EOF
fi
sysctl -p /etc/sysctl.d/99-frr-routing.conf
echo "[OK] sysctl applied"

# =============================================================================
# Route fix: ensure host gateway is reachable via FRR_IFACE (not eth0)
# =============================================================================
# In loxilb onearm mode, return packets are sent to FRR's MAC with dst=gateway.
# Without this fix, FRR routes them via eth0 (Vagrant management) instead of
# FRR_IFACE (data plane), breaking the return path.
if [ "$LB_PROVIDER" = "loxilb" ]; then
  GATEWAY_IP="${NETWORK_PREFIX}.1"
  echo "[INFO] Adding host gateway route: ${GATEWAY_IP}/32 dev ${FRR_IFACE}"
  ip route replace "${GATEWAY_IP}/32" dev "$FRR_IFACE"

  # Persist across reboots via networkd-dispatcher
  cat > /etc/networkd-dispatcher/routable.d/51-frr-gateway-route.sh << GWROUTE_EOF
#!/bin/bash
if [[ "\$IFACE" == "${FRR_IFACE}" ]]; then
  ip route replace ${GATEWAY_IP}/32 dev ${FRR_IFACE}
fi
GWROUTE_EOF
  chmod +x /etc/networkd-dispatcher/routable.d/51-frr-gateway-route.sh
  echo "[OK] Host gateway route added and persisted"
fi

# =============================================================================
# Start FRR
# =============================================================================
echo "[INFO] Restarting FRR..."
systemctl enable frr
systemctl restart frr
sleep 3

# Verify FRR is running
if systemctl is-active --quiet frr; then
  echo "[OK] FRR is running"
else
  echo "[WARN] FRR may not be running. Check: systemctl status frr"
fi

# =============================================================================
# Verify BGP (best-effort, neighbors may not be up yet)
# =============================================================================
echo "[INFO] Waiting 10s for BGP sessions to establish..."
sleep 10

echo "[INFO] BGP summary (neighbors may still be connecting):"
vtysh -c "show bgp summary" 2>/dev/null || echo "[INFO] vtysh not yet ready"

echo ""
echo "[OK] FRR BGP router provisioned successfully"
echo "[INFO] Verify BGP sessions after cluster is up:"
echo "  vagrant ssh $(hostname) -- sudo vtysh -c 'show bgp summary'"
if [ "$LB_PROVIDER" = "loxilb" ]; then
  echo "  # Expected: ${LOXILB_IPS[*]} (Established) + ${MASTER_IP} (Established)"
else
  echo "  # Expected: ${MASTER_IP} (Established)"
fi

# =============================================================================
# Verify VRRP
# =============================================================================
if [[ "$VRRP_ENABLED" == "true" ]]; then
  echo ""
  echo "[INFO] VRRP status:"
  vtysh -c "show vrrp" 2>/dev/null || echo "[INFO] vrrpd not yet ready"
  echo ""
  echo "[INFO] VRRP anycast configured:"
  echo "  VIP:      $VRRP_VIP (shared between all FRR instances)"
  echo "  VRID:     $VRRP_VRID"
  echo "  Priority: $VRRP_PRIORITY (100=master, 50=backup)"
  echo ""
  echo "[INFO] To route host traffic via VRRP VIP:"
  echo "  sudo ip route replace 192.168.121.210/32 via $VRRP_VIP dev virbr0"
  echo "  sudo ip route replace 192.168.121.201/32 via $VRRP_VIP dev virbr0"
fi
