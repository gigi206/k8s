#!/usr/bin/env bash
#
# Configure Canal CNI for RKE2 cluster
# Canal = Flannel (VXLAN overlay) + Calico Felix (network policies via iptables)
#
# Canal is the RKE2 default CNI. This script configures it via HelmChartConfig.
# Canal does NOT replace kube-proxy (unlike Cilium eBPF or Calico BPF).
#
# Configuration options:
#   CANAL_BACKEND: vxlan (default) | wireguard
#   CANAL_MTU: MTU for Flannel VXLAN (default: 1450 = 1500 - 50 VXLAN overhead)
#
# Docs: https://docs.rke2.io/networking/basic_network_options

set -e

CANAL_MTU="${CANAL_MTU:-1450}"
CANAL_BACKEND="${CANAL_BACKEND:-vxlan}"

echo "Configuring Canal HelmChartConfig..."
mkdir -p /var/lib/rancher/rke2/server/manifests

cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-canal-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-canal
  namespace: kube-system
spec:
  valuesContent: |-
    flannel:
      iface: "eth1"
      backend: "${CANAL_BACKEND}"
    calico:
      calicoKubeControllers: true
      mtu: ${CANAL_MTU}
      felix:
        prometheusMetricsEnabled: true
EOF

echo "✓ Canal HelmChartConfig created"
echo "  - Backend: $CANAL_BACKEND"
echo "  - MTU: $CANAL_MTU"
echo "  - Interface: eth1"
echo "  - Prometheus metrics: enabled (Felix:9091)"

# Auto-create HostEndpoints for host firewall policies
# calicoKubeControllers: true (above) deploys calico-kube-controllers which processes this CRD.
# The chart does NOT expose hostEndpoint.autoCreate in values.yaml, so we create the CRD directly.
# This is required for default-deny-host-ingress.yaml (selector: has(kubernetes-host))
# RKE2 auto-applies manifests in /var/lib/rancher/rke2/server/manifests/
cat <<EOF >/var/lib/rancher/rke2/server/manifests/canal-kube-controllers-config.yaml
apiVersion: crd.projectcalico.org/v1
kind: KubeControllersConfiguration
metadata:
  name: default
spec:
  controllers:
    node:
      hostEndpoint:
        autoCreate: Enabled
EOF

echo "✓ KubeControllersConfiguration created (HostEndpoint autoCreate: Enabled)"
echo ""
echo "✓ Canal CNI configuration completed successfully"
