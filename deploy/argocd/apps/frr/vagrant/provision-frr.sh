#!/usr/bin/env bash
# =============================================================================
# Provision FRR BGP Upstream Router inside dedicated Vagrant VM
# =============================================================================
# Runs on a separate VM (k8s-<cluster>-frr) to simulate a physical BGP router
# upstream of both LoxiLB and Cilium in pure BGP mode (loadBalancer.mode: bgp).
#
# Topology:
#   loxilb (ASN 65002) <-eBGP-> FRR (ASN 65000) <-eBGP-> Cilium (ASN 64512)
#
# FRR acts as a route reflector / ECMP router:
#   - Learns VIP /32 routes from loxilb via eBGP
#   - Learns PodCIDR routes from Cilium via eBGP
#   - Proxy-ARP on eth1: responds to ARP for VIPs -> forwards to loxilb
#   - ip_forward: routes packets between loxilb and cluster nodes
#
# Called conditionally by Vagrantfile when:
#   LB_PROVIDER=loxilb and LB_MODE=bgp
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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

# Read ASNs from config
FRR_ASN=$(yq '.frr.asn' "$ARGOCD_CONFIG" 2>/dev/null || echo "65000")
CILIUM_ASN=$(yq '.features.loadBalancer.bgp.localASN' "$ARGOCD_CONFIG" 2>/dev/null || echo "64512")

# Read loxilb config
if [ ! -f "$LOXILB_APP_CONFIG" ]; then
  echo "[WARN] LoxiLB config not found: $LOXILB_APP_CONFIG"
  exit 1
fi
LOXILB_ASN=$(yq '.loxilb.bgp.localASN' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "65002")
LOXILB_URL=$(yq '.loxilb.loxiURL' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "http://192.168.121.40:11111")
# Extract loxilb IP from URL (http://192.168.121.40:11111 -> 192.168.121.40)
LOXILB_IP=$(echo "$LOXILB_URL" | sed 's|https\?://\([0-9.]*\):.*|\1|')

# Determine eth1 IP (this VM: .45), master IP (.50)
ETH1_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
if [ -z "$ETH1_IP" ]; then
  echo "[WARN] eth1 has no IPv4 address yet, using configured IP from frr.ip"
  ETH1_IP=$(yq '.frr.ip' "$ARGOCD_CONFIG" 2>/dev/null || echo "192.168.121.45")
fi
# Derive master IP by replacing last octet with 50
NETWORK_PREFIX=$(echo "$ETH1_IP" | cut -d. -f1-3)
MASTER_IP="${NETWORK_PREFIX}.50"

echo "[INFO] FRR BGP router provisioning (mode: bgp)"
echo "[INFO]   FRR IP:       $ETH1_IP (eth1)"
echo "[INFO]   FRR ASN:      $FRR_ASN"
echo "[INFO]   LoxiLB IP:    $LOXILB_IP (ASN $LOXILB_ASN)"
echo "[INFO]   Master IP:    $MASTER_IP (Cilium ASN $CILIUM_ASN)"

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
grep "^bgpd=" /etc/frr/daemons

# =============================================================================
# Generate /etc/frr/frr.conf
# =============================================================================
echo "[INFO] Writing /etc/frr/frr.conf..."
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
 neighbor ${LOXILB_IP} remote-as ${LOXILB_ASN}
 neighbor ${LOXILB_IP} description loxilb-external
 neighbor ${LOXILB_IP} ebgp-multihop 2
 !
 neighbor ${MASTER_IP} remote-as ${CILIUM_ASN}
 neighbor ${MASTER_IP} description cilium-master
 neighbor ${MASTER_IP} ebgp-multihop 2
 !
 address-family ipv4 unicast
  neighbor ${LOXILB_IP} activate
  neighbor ${LOXILB_IP} soft-reconfiguration inbound
  neighbor ${MASTER_IP} activate
  neighbor ${MASTER_IP} soft-reconfiguration inbound
  maximum-paths 2
 exit-address-family
!
line vty
!
EOF

echo "[OK] /etc/frr/frr.conf written"

# =============================================================================
# Sysctl: ip_forward + proxy_arp on eth1
# =============================================================================
echo "[INFO] Setting sysctl (ip_forward + proxy_arp on eth1)..."
cat > /etc/sysctl.d/99-frr-routing.conf << EOF
# FRR BGP upstream router - IP forwarding and proxy-ARP for VIPs
net.ipv4.ip_forward = 1
net.ipv4.conf.eth1.proxy_arp = 1
EOF
sysctl -p /etc/sysctl.d/99-frr-routing.conf
echo "[OK] sysctl applied"

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
echo "  vagrant ssh k8s-${K8S_ENV}-frr -- sudo vtysh -c 'show bgp summary'"
echo "  # Expected: ${LOXILB_IP} (Established) + ${MASTER_IP} (Established)"
