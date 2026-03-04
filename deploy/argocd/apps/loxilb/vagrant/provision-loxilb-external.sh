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
LB_MODE=$(yq '.features.loadBalancer.mode' "$ARGOCD_CONFIG" 2>/dev/null || echo "l2")
LB_MODE=${LB_MODE:-l2}

# In L2 mode, BGP peers are configured directly via loxilb API (not kube-loxilb).
# In BGP mode, kube-loxilb handles this via --setBGP and --extBGPPeers.
if [ "$LOXILB_BGP_ENABLED" = "true" ]; then
  LOXILB_BGP_LOCAL_ASN=$(yq '.loxilb.bgp.localASN' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "")
  LOXILB_BGP_EXT_PEERS=$(yq '.loxilb.bgp.extBGPPeers' "$LOXILB_APP_CONFIG" 2>/dev/null || echo "")
fi

echo "[INFO] LoxiLB external mode enabled, provisioning..."
echo "[INFO]   BGP: ${LOXILB_BGP_ENABLED}, LB mode: ${LB_MODE}"

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

# Write BGP flag for boot-time BGP readiness gate
if [ "$LOXILB_BGP_ENABLED" = "true" ]; then
  echo "true" > /etc/loxilb/bgp-enabled
fi

# Persist BGP config for boot-time reconfiguration (L2+BGP mode).
# GoBGP loses API config on container restart; this file is read by
# loxilb-bgp-config.service to reconfigure after every boot.
if [ "$LOXILB_BGP_ENABLED" = "true" ] && [ "$LB_MODE" = "l2" ]; then
  cat > /etc/loxilb/bgp-config.env << BGPENV
LOXILB_BGP_LOCAL_ASN=${LOXILB_BGP_LOCAL_ASN}
LOXILB_BGP_EXT_PEERS=${LOXILB_BGP_EXT_PEERS}
BGPENV
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

# -----------------------------------------------------------------------
# Fix 5: BGP readiness gate — block BGP until LB rules are synced
# -----------------------------------------------------------------------
# GoBGP announces VIP routes ~1s BEFORE the eBPF datapath (DP) is
# programmed for each rule. During this gap, ECMP traffic arrives
# but there's no DNAT rule → eBPF drops → connection failures.
# Fix: block TCP 179 (BGP) via iptables. loxilb-bgp-gate.sh will
# unblock once LB rules stabilize in the API (all DP rules ready).
# Covers: first provision, VM reboot, vagrant destroy+up.
# Skip if loxilb container is already running (re-provision case).
# -----------------------------------------------------------------------
if [ -f /etc/loxilb/bgp-enabled ]; then
  SHOULD_BLOCK=true
  # Skip block only if docker is running AND container is active (re-provision case).
  # IMPORTANT: do NOT call "docker inspect" unless docker.service is active.
  # At boot (Before=docker.service), docker.socket activation would deadlock:
  # eth0-fix waits for docker inspect → docker.socket triggers docker.service
  # → docker.service blocked by Before= ordering → hang.
  if systemctl is-active --quiet docker.service 2>/dev/null && \
     docker inspect --format='{{.State.Running}}' loxilb-external 2>/dev/null | grep -q "true"; then
    SHOULD_BLOCK=false
  fi
  if [ "$SHOULD_BLOCK" = "true" ]; then
    iptables -C INPUT -i eth1 -p tcp --dport 179 -j DROP 2>/dev/null || \
      iptables -I INPUT -i eth1 -p tcp --dport 179 -j DROP
    iptables -C OUTPUT -o eth1 -p tcp --dport 179 -j DROP 2>/dev/null || \
      iptables -I OUTPUT -o eth1 -p tcp --dport 179 -j DROP
    echo "[OK] BGP blocked on eth1 (waiting for loxilb-bgp-gate)"
  else
    echo "[OK] BGP block skipped (loxilb container already running)"
  fi
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

# BGP readiness gate: unblock BGP after loxilb LB rules are synced by kube-loxilb.
# loxilb-eth0-fix.sh blocks TCP 179 (Fix 5). This script polls the loxilb API
# and waits for the LB rule count to STABILIZE before unblocking BGP.
# Why stability? loxilb announces each VIP route via GoBGP ~1s BEFORE programming
# the eBPF datapath. By waiting for all rules to be synced (stable count), we
# ensure all DP rules are programmed before GoBGP can advertise any routes.
# Safety valve: unblock after 300s even without rules (prevents permanent BGP blackout).
cat > /usr/local/bin/loxilb-bgp-gate.sh << 'GATESCRIPT'
#!/bin/bash
MAX_WAIT=300
POLL=5
ELAPSED=0
STABLE_REQUIRED=3   # consecutive polls with same count before unblocking

# Nothing to do if BGP isn't blocked
if ! iptables -C INPUT -i eth1 -p tcp --dport 179 -j DROP 2>/dev/null; then
  echo "[OK] BGP not blocked, nothing to do"
  exit 0
fi

echo "[INFO] BGP gate: waiting for loxilb LB rules..."

unblock_bgp() {
  iptables -D INPUT -i eth1 -p tcp --dport 179 -j DROP 2>/dev/null
  iptables -D OUTPUT -o eth1 -p tcp --dport 179 -j DROP 2>/dev/null
}

# Wait for loxilb API to be ready first
while [ $ELAPSED -lt $MAX_WAIT ]; do
  if curl -s -o /dev/null "http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all" 2>/dev/null; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  unblock_bgp
  echo "[WARN] BGP unblocked by safety valve: loxilb API never became ready (${MAX_WAIT}s)"
  exit 1
fi

echo "[INFO] BGP gate: loxilb API ready after ${ELAPSED}s, polling for LB rules..."

# Wait for LB rules to stabilize (all rules synced by kube-loxilb).
# Unblock BGP only after rule count stays constant for STABLE_REQUIRED
# consecutive polls. This ensures ALL DP rules are programmed before
# GoBGP can advertise any routes, preventing per-rule BGP-before-DP race.
PREV_COUNT=0
STABLE_TICKS=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
  RULES=$(curl -s "http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all" 2>/dev/null)
  CURRENT_COUNT=$(echo "$RULES" | grep -c '"externalIP"' || true)

  if [ "$CURRENT_COUNT" -gt 0 ]; then
    if [ "$CURRENT_COUNT" -eq "$PREV_COUNT" ]; then
      STABLE_TICKS=$((STABLE_TICKS + 1))
      if [ $STABLE_TICKS -ge $STABLE_REQUIRED ]; then
        unblock_bgp
        echo "[OK] BGP unblocked: $CURRENT_COUNT LB rule(s) stable for $((STABLE_REQUIRED * POLL))s (${ELAPSED}s total)"
        exit 0
      fi
    else
      echo "[INFO] BGP gate: rule count $PREV_COUNT -> $CURRENT_COUNT"
      STABLE_TICKS=0
    fi
    PREV_COUNT=$CURRENT_COUNT
  fi

  sleep $POLL
  ELAPSED=$((ELAPSED + POLL))
done

# Safety valve: unblock anyway to prevent permanent BGP blackout
unblock_bgp
if [ "$PREV_COUNT" -gt 0 ]; then
  echo "[WARN] BGP unblocked by safety valve after ${MAX_WAIT}s ($PREV_COUNT rules, not stable)"
else
  echo "[WARN] BGP unblocked by safety valve after ${MAX_WAIT}s (no LB rules detected)"
fi
GATESCRIPT
chmod +x /usr/local/bin/loxilb-bgp-gate.sh

cat > /etc/systemd/system/loxilb-bgp-gate.service << 'GATESERVICE'
[Unit]
Description=Unblock BGP after loxilb LB rules are synced
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/loxilb-bgp-gate.sh
# Long timeout: safety valve is 300s + API wait
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
GATESERVICE

# BGP config script: reconfigure GoBGP via API after container restart (L2+BGP).
# In L2 mode, kube-loxilb does NOT pass --setBGP, so GoBGP has no config after
# a container restart. This script reads persisted config from /etc/loxilb/bgp-config.env
# and re-applies it via HTTP API. In BGP mode, kube-loxilb handles this automatically.
# Idempotent: checks existing config before applying. Safe to call repeatedly (timer).
cat > /usr/local/bin/loxilb-bgp-config.sh << 'BGPSCRIPT'
#!/bin/bash
set -uo pipefail

CONFIG_FILE="/etc/loxilb/bgp-config.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[OK] No BGP config to apply (not L2+BGP mode)"
  exit 0
fi

source "$CONFIG_FILE"
if [ -z "${LOXILB_BGP_LOCAL_ASN:-}" ] || [ -z "${LOXILB_BGP_EXT_PEERS:-}" ]; then
  echo "[WARN] BGP config incomplete, skipping"
  exit 0
fi

# Check if loxilb container is running
CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep loxilb 2>/dev/null | head -1)
if [ -z "$CONTAINER_NAME" ]; then
  echo "[INFO] loxilb container not running, skipping"
  exit 1
fi

# Wait for loxilb API (short timeout for timer invocations, longer for first boot)
ELAPSED=0
MAX_WAIT=30
while [ $ELAPSED -lt $MAX_WAIT ]; do
  if curl -s -o /dev/null "http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all" 2>/dev/null; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "[ERROR] loxilb API not ready after ${MAX_WAIT}s"
  exit 1
fi

NODE_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Idempotency check: query existing BGP global config.
# If neighbors already exist with correct config, skip reconfiguration.
EXISTING_NEIGH=$(curl -s "http://127.0.0.1:11111/netlox/v1/config/bgp/neigh" 2>/dev/null || echo "")
IFS=',' read -ra PEERS <<< "$LOXILB_BGP_EXT_PEERS"
ALL_PEERS_CONFIGURED=true
for peer in "${PEERS[@]}"; do
  peer_ip="${peer%%:*}"
  if ! echo "$EXISTING_NEIGH" | grep -q "\"ipAddress\":\"${peer_ip}\""; then
    ALL_PEERS_CONFIGURED=false
    break
  fi
done

if [ "$ALL_PEERS_CONFIGURED" = "true" ] && [ ${#PEERS[@]} -gt 0 ]; then
  echo "[OK] BGP already configured (${#PEERS[@]} peer(s) present), nothing to do"
  exit 0
fi

# GoBGP starts asynchronously inside loxilb. The REST API (port 11111) becomes
# ready before GoBGP's internal gRPC (port 50052) is connected. If we POST the
# BGP global config too early, the REST API returns 200 but GoBGP never receives
# the config. Retry until GoBGP confirms the ASN is set (cistate shows the BGP
# handler acknowledged the config via the "BGP session ready" path).
echo "[INFO] Configuring BGP via API (AS ${LOXILB_BGP_LOCAL_ASN}, routerId ${NODE_IP})..."
BGP_CONFIGURED=false
BGP_RETRIES=0
BGP_MAX_RETRIES=30
while [ "$BGP_CONFIGURED" = "false" ] && [ $BGP_RETRIES -lt $BGP_MAX_RETRIES ]; do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://127.0.0.1:11111/netlox/v1/config/bgp/global" \
    -H "Content-Type: application/json" \
    -d "{\"localAs\": ${LOXILB_BGP_LOCAL_ASN}, \"routerId\": \"${NODE_IP}\"}" 2>/dev/null)

  if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
    # Verify GoBGP actually accepted the config by checking the container logs.
    # "BGP session ready" means GoBGP saw ASN != 0 after our POST.
    if docker logs "$CONTAINER_NAME" 2>&1 | tail -20 | grep -q "BGP session.*ready"; then
      BGP_CONFIGURED=true
      break
    fi
  fi

  BGP_RETRIES=$((BGP_RETRIES + 1))
  if [ $BGP_RETRIES -lt $BGP_MAX_RETRIES ]; then
    sleep 2
  fi
done

if [ "$BGP_CONFIGURED" = "true" ]; then
  echo "[OK] BGP global AS ${LOXILB_BGP_LOCAL_ASN} configured (verified after ${BGP_RETRIES} attempts)"
else
  echo "[WARN] BGP global config not confirmed after ${BGP_MAX_RETRIES} retries (GoBGP may not be ready)"
  exit 1
fi

for peer in "${PEERS[@]}"; do
  peer_ip="${peer%%:*}"
  peer_asn="${peer##*:}"
  # Skip if peer already exists
  if echo "$EXISTING_NEIGH" | grep -q "\"ipAddress\":\"${peer_ip}\""; then
    echo "[OK] BGP peer ${peer_ip} (AS ${peer_asn}) already configured"
    continue
  fi
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://127.0.0.1:11111/netlox/v1/config/bgp/neigh" \
    -H "Content-Type: application/json" \
    -d "{\"ipAddress\": \"${peer_ip}\", \"remoteAs\": ${peer_asn}}" 2>/dev/null)
  if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
    echo "[OK] BGP peer ${peer_ip} (AS ${peer_asn}) added"
  else
    echo "[WARN] BGP peer ${peer_ip} returned HTTP ${http_code}"
  fi
done
BGPSCRIPT
chmod +x /usr/local/bin/loxilb-bgp-config.sh

cat > /etc/systemd/system/loxilb-bgp-config.service << 'BGPCONFIGSERVICE'
[Unit]
Description=Reconfigure GoBGP via loxilb API after container restart (L2+BGP)
After=docker.service
Before=loxilb-bgp-gate.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/loxilb-bgp-config.sh
TimeoutStartSec=180
BGPCONFIGSERVICE

# Timer: re-check BGP config periodically.
# Handles Docker container restart (GoBGP loses in-memory state) and
# initial provisioning where multi-user.target is already reached.
# The script is idempotent: exits immediately if config is already present.
cat > /etc/systemd/system/loxilb-bgp-config.timer << 'BGPCONFIGTIMER'
[Unit]
Description=Periodic BGP config re-check for loxilb (handles container restart)

[Timer]
# First run 30s after boot (covers initial provisioning)
OnBootSec=30
# Re-check every 30s (idempotent, exits fast if already configured)
OnUnitActiveSec=30
# Randomize slightly to avoid thundering herd across VMs
RandomizedDelaySec=5

[Install]
WantedBy=timers.target
BGPCONFIGTIMER

systemctl daemon-reload
systemctl enable loxilb-eth0-fix.service
systemctl enable loxilb-bgp-gate.service
systemctl enable loxilb-bgp-config.service
systemctl enable loxilb-bgp-config.timer
# Start the timer now — covers initial provisioning where multi-user.target
# is already reached and the oneshot service won't auto-start.
# The timer fires every 30s until BGP is configured, then the idempotent
# script exits immediately on each subsequent invocation.
systemctl start loxilb-bgp-config.timer
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
  # Clean up BGP iptables block from the manual boot script run above (re-provision case)
  iptables -D INPUT -i eth1 -p tcp --dport 179 -j DROP 2>/dev/null || true
  iptables -D OUTPUT -o eth1 -p tcp --dport 179 -j DROP 2>/dev/null || true
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

    # In L2 mode, configure BGP peers directly via loxilb API for PodCIDR routing.
    # kube-loxilb does NOT pass --setBGP in L2 mode (it would mark VIPs as
    # BGP-announced instead of GARP/ARP). So we configure BGP here instead.
    # In BGP mode, kube-loxilb handles this via --setBGP/--extBGPPeers.
    # Uses the same script as the systemd boot service (single source of truth).
    # Non-fatal: if GoBGP isn't ready yet, the timer will retry every 30s.
    if [ "$LOXILB_BGP_ENABLED" = "true" ] && [ "$LB_MODE" = "l2" ]; then
      /usr/local/bin/loxilb-bgp-config.sh || echo "[INFO] BGP config deferred to timer (GoBGP not ready yet)"
    fi

    # Start BGP gate in background: unblocks BGP after LB rules stabilize.
    # On first provision, systemd gate service won't auto-start until next boot.
    # On re-provision (container already running), gate exits immediately (no block).
    if [ "$LOXILB_BGP_ENABLED" = "true" ]; then
      nohup /usr/local/bin/loxilb-bgp-gate.sh &>/var/log/loxilb-bgp-gate.log &
      echo "[INFO] BGP gate started in background (PID: $!)"
    fi

    exit 0
  fi
  retries=$((retries + 1))
  sleep 2
done

echo "[WARN] LoxiLB API did not become ready within ${max_retries} retries"
echo "[WARN] Check container logs: docker logs ${CONTAINER_NAME}"
