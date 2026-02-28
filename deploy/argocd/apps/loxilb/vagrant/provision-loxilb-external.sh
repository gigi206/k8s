#!/usr/bin/env bash
# =============================================================================
# Provision LoxiLB External Container inside dedicated Vagrant VM
# =============================================================================
# Runs on a separate VM (k8s-<cluster>-loxilb) to avoid eBPF conflicts with
# Cilium running on the master/worker nodes.
# LoxiLB runs as a Docker container with --net=host inside this VM.
#
# Called conditionally by Vagrantfile when LB_PROVIDER=loxilb.
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Determine project root
if [ -f "/vagrant/vagrant/scripts/RKE2_ENV.sh" ]; then
  PROJECT_ROOT="/vagrant"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

# Read environment from Vagrant env (default: dev)
K8S_ENV="${K8S_ENV:-dev}"

ARGOCD_CONFIG="$PROJECT_ROOT/deploy/argocd/config/config.yaml"
LOXILB_APP_CONFIG="$PROJECT_ROOT/deploy/argocd/apps/loxilb/config/${K8S_ENV}.yaml"

# Check if loxilb app config exists
if [ ! -f "$LOXILB_APP_CONFIG" ]; then
  echo "[WARN] LoxiLB config not found: $LOXILB_APP_CONFIG"
  exit 0
fi

# Check if LoxiLB external mode is enabled
LB_PROVIDER=$(yq '.features.loadBalancer.provider' "$ARGOCD_CONFIG" 2>/dev/null || echo "")
LOXILB_MODE=$(yq '.loxilb.mode' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "internal")

if [[ "$LB_PROVIDER" != "loxilb" ]] || [[ "$LOXILB_MODE" != "external" ]]; then
  echo "[INFO] LoxiLB external mode not enabled (provider=$LB_PROVIDER, mode=$LOXILB_MODE), skipping."
  exit 0
fi

# Read BGP setting from app config
LOXILB_BGP_ENABLED=$(yq '.loxilb.bgp.enabled' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "false")
LOXILB_BGP_ENABLED=${LOXILB_BGP_ENABLED:-false}

echo "[INFO] LoxiLB external mode enabled, provisioning..."
echo "[INFO]   BGP: ${LOXILB_BGP_ENABLED}"

# =============================================================================
# Fix dual-interface ARP issue (eth0 Vagrant management + eth1 loxilb working)
# =============================================================================
# Root cause: both eth0 and eth1 are on the same subnet (192.168.121.0/24).
# LoxiLB's IfaSelectAny() selects the GARP interface by scanning its internal
# route trie. At startup, eth0 is processed before eth1 by NlpGet(), so
# eth0's /24 subnet route is added to loxilb's trie first. eth1's identical
# subnet route then fails ("subnet-route add error"). IfaSelectAny() for any
# VIP in 192.168.121.0/24 then resolves to eth0 → GARP sent with eth0 MAC.
# Traffic from the host arrives on eth0 instead of eth1, bypassing the eBPF
# hook, and the kernel sends RST (no listener on eth0 for the VIP ports).
#
# Fix 1 (IfaSelectAny): change eth0 from /24 to /32. With /32, eth0's subnet
# is just 192.168.121.5/32 (not /24), so it doesn't match the VIP subnet.
# loxilb's trie then has only the eth1 /24 route, and IfaSelectAny() always
# returns eth1 → GARP sent with eth1 MAC → traffic flows correctly.
#
# Fix 2 (kernel ARP): set arp_ignore=1 on eth0 so the kernel doesn't respond
# to broadcast ARP requests for VIPs (which live on lo). Without this, eth0
# would answer ARP for VIPs (since they're local IPs) even after Fix 1.
# =============================================================================

# Fix 2: persist arp_ignore=1 for eth0
cat > /etc/sysctl.d/99-loxilb-arp.conf << 'EOF'
net.ipv4.conf.eth0.arp_ignore = 1
EOF
sysctl -w net.ipv4.conf.eth0.arp_ignore=1
echo "[OK] arp_ignore=1 set on eth0 (persistent)"

# Install arping for gateway MAC resolution at boot time
# (loxilb-eth0-fix.sh runs Before=docker.service when eth0 ARP cache is empty)
if ! command -v arping &>/dev/null; then
  apt-get install -y -qq iputils-arping
  echo "[OK] iputils-arping installed"
fi

# Write extra neighbor IPs to resolve at boot (e.g., VRRP VIP)
mkdir -p /etc/loxilb
> /etc/loxilb/extra-neighbors.conf
VRRP_ENABLED=$(yq '.features.loadBalancer.bgp.vrrp.enabled' "$ARGOCD_CONFIG" 2>/dev/null || echo "false")
VRRP_VIP=$(yq '.features.loadBalancer.bgp.vrrp.vip' "$ARGOCD_CONFIG" 2>/dev/null || echo "")
if [ "$VRRP_ENABLED" = "true" ] && [ -n "$VRRP_VIP" ] && [ "$VRRP_VIP" != "null" ]; then
  echo "$VRRP_VIP" >> /etc/loxilb/extra-neighbors.conf
  echo "[OK] VRRP VIP ${VRRP_VIP} added to boot-time neighbor resolution"
fi

# Fix 1: create a systemd service to set eth0 to /32 before Docker starts.
# This runs at every boot (Before=docker.service) to ensure loxilb always
# sees eth0 as /32. DHCP may restore /24 on renewal, but this service re-fixes
# it before Docker (and loxilb) starts on the next boot.
cat > /usr/local/bin/loxilb-eth0-fix.sh << 'SCRIPT'
#!/bin/bash
# Change eth0 from /24 to /32 so loxilb IfaSelectAny() picks eth1 for GARPs.
ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
[ -z "$ETH0_IP" ] && { echo "[WARN] eth0 has no IPv4, skipping"; exit 0; }
MASK=$(ip -4 addr show eth0 | awk '/inet /{split($2,a,"/"); print a[2]; exit}')
if [ "$MASK" != "32" ]; then
  ip addr del "${ETH0_IP}/24" dev eth0 2>/dev/null || true
  ip addr add "${ETH0_IP}/32" dev eth0
  ip route add 192.168.121.1/32 dev eth0 scope link 2>/dev/null || true
  ip route add default via 192.168.121.1 dev eth0 2>/dev/null || true
  echo "[OK] eth0 set to /32: ${ETH0_IP}/32"
else
  echo "[OK] eth0 already /32, skipping"
fi

# -----------------------------------------------------------------------
# Fix 3: add permanent neighbors on eth1 for loxilb eBPF reverse NAT
# -----------------------------------------------------------------------
# With eth0 set to /32, the kernel routes the gateway via eth0 exclusively.
# loxilb (--whitelist=eth1) only monitors eth1 neighbors for its internal
# neighbor map (populated via netlink from the kernel ARP cache — NOT via
# bpf_fib_lookup). On the reverse NAT path (SYN-ACK from backend → client),
# the eBPF looks up the client's next-hop L2 addr in this internal map.
# If the client is behind the gateway (e.g. the hypervisor at .1), the
# gateway's MAC is not in loxilb's eth1 neighbor table → the lookup fails
# → eBPF returns TC_ACT_OK → kernel sends RST (no socket).
#
# Fix: add permanent ARP entries on eth1 for:
#   - gateway (for clients behind the default route)
#   - VRRP VIP (for traffic routed via the FRR anycast VIP)
# Uses arping with retry loop since eth0 ARP cache is empty at early boot.
# -----------------------------------------------------------------------
resolve_and_add_neighbor() {
  local TARGET_IP="$1"
  local RESOLVED_MAC=""
  for attempt in $(seq 1 10); do
    # Method 1: arping on eth1 (active ARP request, works with empty cache)
    if command -v arping &>/dev/null; then
      RESOLVED_MAC=$(arping -I eth1 -c 1 -w 3 "$TARGET_IP" 2>/dev/null | awk '/reply/{print $5; exit}' | tr -d '[]')
    fi
    # Method 2: ping to populate ARP cache, then read
    if [ -z "$RESOLVED_MAC" ]; then
      ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1 || true
      RESOLVED_MAC=$(ip neigh show "$TARGET_IP" 2>/dev/null | awk '/lladdr/{print $5; exit}')
    fi
    if [ -n "$RESOLVED_MAC" ]; then
      ip neigh replace "$TARGET_IP" lladdr "$RESOLVED_MAC" dev eth1 nud permanent 2>/dev/null
      echo "[OK] ${TARGET_IP} (${RESOLVED_MAC}) added to eth1 neighbor table"
      return 0
    fi
    echo "[INFO] MAC for ${TARGET_IP} not resolved (attempt $attempt/10), retrying..."
    sleep 2
  done
  echo "[WARN] Could not resolve MAC for ${TARGET_IP} after 10 attempts"
  return 1
}

# Gateway neighbor (reverse NAT for clients behind default route)
GW_IP=$(ip route show default dev eth0 2>/dev/null | awk '/via/{print $3; exit}')
if [ -n "$GW_IP" ]; then
  resolve_and_add_neighbor "$GW_IP"
fi

# Extra neighbors from provisioning config (e.g., VRRP VIP)
if [ -f /etc/loxilb/extra-neighbors.conf ]; then
  while IFS= read -r extra_ip || [ -n "$extra_ip" ]; do
    [ -z "$extra_ip" ] && continue
    resolve_and_add_neighbor "$extra_ip"
  done < /etc/loxilb/extra-neighbors.conf
fi
SCRIPT
chmod +x /usr/local/bin/loxilb-eth0-fix.sh

cat > /etc/systemd/system/loxilb-eth0-fix.service << 'SERVICE'
[Unit]
Description=Fix eth0 to /32 and add gateway neighbor on eth1 for loxilb
After=network-online.target
Before=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/loxilb-eth0-fix.sh

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable loxilb-eth0-fix.service
/usr/local/bin/loxilb-eth0-fix.sh

# Install Docker if not present
if ! command -v docker &>/dev/null; then
  echo "[INFO] Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  echo "[OK] Docker installed"
fi

# Read image/tag from app config (same versions tracked by Renovate)
LOXILB_IMAGE=$(yq '.loxilb.loxilbImage' "$LOXILB_APP_CONFIG")
LOXILB_TAG=$(yq '.loxilb.loxilbTag' "$LOXILB_APP_CONFIG")
CONTAINER_NAME="loxilb-external"

# Check if already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "[OK] LoxiLB external container already running"
  exit 0
fi

# Remove stopped container if exists
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

echo "[INFO] Starting LoxiLB external container..."
echo "[INFO]   Image: ${LOXILB_IMAGE}:${LOXILB_TAG}"
echo "[INFO]   Network: host (--net=host inside VM)"

# Build docker run command with optional --bgp flag
DOCKER_CMD=(docker run -u root
  --cap-add SYS_ADMIN
  --restart unless-stopped
  --privileged
  -dit
  --name "${CONTAINER_NAME}"
  --net=host
)

# Restrict eBPF and netlink processing to eth1 only (--whitelist).
# This ensures IfaSelectAny() resolves to eth1 for GARP, so VIPs are
# advertised with eth1's MAC. Combined with arp_ignore=1 on eth0,
# all VIP traffic flows through a single interface, avoiding the
# cross-interface conntrack issue.
LOXILB_ARGS=("--whitelist=eth1")

if [ "$LOXILB_BGP_ENABLED" = "true" ]; then
  echo "[INFO]   BGP: enabled (GoBGP will be started inside the container)"
  LOXILB_ARGS+=("--bgp")
fi

DOCKER_CMD+=("${LOXILB_IMAGE}:${LOXILB_TAG}" "${LOXILB_ARGS[@]}")

"${DOCKER_CMD[@]}"

echo "[OK] Container ${CONTAINER_NAME} started"

# Wait for API to be ready
echo "[INFO] Waiting for LoxiLB API..."
retries=0
max_retries=30
while [ $retries -lt $max_retries ]; do
  if curl -s -o /dev/null "http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all" 2>/dev/null; then
    NODE_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    echo "[OK] LoxiLB API is ready"
    echo "[INFO] kube-loxilb should use: --loxiURL=http://${NODE_IP}:11111"
    exit 0
  fi
  retries=$((retries + 1))
  sleep 2
done

echo "[WARN] LoxiLB API did not become ready within ${max_retries} retries"
echo "[WARN] Check container logs: docker logs ${CONTAINER_NAME}"
