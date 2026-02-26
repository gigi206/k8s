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

# Determine eth1 IP (this VM: .45), master IP (.50)
ETH1_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
if [ -z "$ETH1_IP" ]; then
  echo "[WARN] eth1 has no IPv4 address yet, using configured peer address"
  ETH1_IP=$(yq '.features.loadBalancer.bgp.peers[0].address // "192.168.121.45"' "$ARGOCD_CONFIG" 2>/dev/null || echo "192.168.121.45")
fi
# Derive master IP by replacing last octet with 50
NETWORK_PREFIX=$(echo "$ETH1_IP" | cut -d. -f1-3)
MASTER_IP="${NETWORK_PREFIX}.50"

echo "[INFO] FRR BGP router provisioning (mode: bgp, provider: $LB_PROVIDER)"
echo "[INFO]   FRR IP:       $ETH1_IP (eth1)"
echo "[INFO]   FRR ASN:      $FRR_ASN"
echo "[INFO]   Cluster ASN:  $CLUSTER_ASN"
echo "[INFO]   Master IP:    $MASTER_IP"

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
echo "  vagrant ssh $(hostname) -- sudo vtysh -c 'show bgp summary'"
if [ "$LB_PROVIDER" = "loxilb" ]; then
  echo "  # Expected: ${LOXILB_IPS[*]} (Established) + ${MASTER_IP} (Established)"
else
  echo "  # Expected: ${MASTER_IP} (Established)"
fi
