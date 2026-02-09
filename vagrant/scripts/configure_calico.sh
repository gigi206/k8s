#!/usr/bin/env bash
#
# Configure Calico CNI for RKE2 cluster
# This script configures Calico with eBPF dataplane (kube-proxy replacement)
#
# Dataplane Selection (CALICO_DATAPLANE environment variable)
# =============================================================================
# CALICO_DATAPLANE=bpf (default): eBPF dataplane, replaces kube-proxy
#   - Higher performance, programmable networking
#   - Requires Linux kernel >= 5.3 (recommended >= 5.7)
#   - Docs: https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf
#
# CALICO_DATAPLANE=iptables: Traditional iptables dataplane
#   - Wider compatibility, well-tested
#   - Requires kube-proxy (do NOT disable rke2-kube-proxy)
#
# Encapsulation (CALICO_ENCAPSULATION environment variable)
# =============================================================================
# CALICO_ENCAPSULATION=VXLAN (default): VXLAN encapsulation
#   - Works in any L3 network, no BGP needed
# CALICO_ENCAPSULATION=IPIP: IP-in-IP encapsulation
#   - Slightly lower overhead than VXLAN
# CALICO_ENCAPSULATION=None: No encapsulation (native routing / BGP)
#   - Requires BGP or direct L2 connectivity
#

set -e

export DEBIAN_FRONTEND=noninteractive
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

CALICO_DATAPLANE="${CALICO_DATAPLANE:-bpf}"
CALICO_ENCAPSULATION="${CALICO_ENCAPSULATION:-VXLAN}"
CALICO_BGP_ENABLED="${CALICO_BGP_ENABLED:-false}"

# Determine BGP setting
if [ "$CALICO_BGP_ENABLED" = "true" ]; then
  CALICO_BGP="Enabled"
else
  CALICO_BGP="Disabled"
fi

# Determine linuxDataplane
if [ "$CALICO_DATAPLANE" = "bpf" ]; then
  LINUX_DATAPLANE="BPF"
  echo "Calico Dataplane: eBPF (kube-proxy replacement)"
else
  LINUX_DATAPLANE="Iptables"
  echo "Calico Dataplane: iptables (traditional)"
fi

echo "Calico Encapsulation: $CALICO_ENCAPSULATION"
echo "Calico BGP: $CALICO_BGP"

echo "Configuring Calico HelmChartConfig..."
mkdir -p /var/lib/rancher/rke2/server/manifests

cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-calico-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-calico
  namespace: kube-system
spec:
  valuesContent: |-
    installation:
      calicoNetwork:
        linuxDataplane: ${LINUX_DATAPLANE}
        bgp: ${CALICO_BGP}
        ipPools:
          - cidr: 10.42.0.0/16
            encapsulation: ${CALICO_ENCAPSULATION}
            natOutgoing: Enabled
            nodeSelector: all()
    # Enable Prometheus metrics on Felix
    felixConfiguration:
      defaultValues:
        prometheusMetricsEnabled: true
        prometheusMetricsPort: 9091
    # Auto-create HostEndpoints for host firewall policies
    kubeControllersConfiguration:
      defaultValues:
        controllers:
          node:
            hostEndpoint:
              autoCreate: Enabled
EOF

echo "✓ Calico HelmChartConfig created"
echo "  - Dataplane: $LINUX_DATAPLANE"
echo "  - Encapsulation: $CALICO_ENCAPSULATION"
echo "  - BGP: $CALICO_BGP"
echo "  - Prometheus metrics: enabled (Felix:9091)"
echo "  - HostEndpoint auto-create: enabled (for host firewall)"
echo ""
echo "✓ Calico CNI configuration completed successfully"
