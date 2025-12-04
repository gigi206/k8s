#!/usr/bin/env bash
#
# Configure Cilium CNI for RKE2 cluster
# This script configures Cilium with full CNI settings
#
# NOTE: L2 announcements are ENABLED but LoadBalancer IPAM is handled by MetalLB
# L2 announcements in Cilium has known ARP bugs on virtualized interfaces in single-node with LoadBalancer IPAM
# For multi-node clusters, MetalLB will handle LoadBalancer IP management (installed via ArgoCD)
#
# HISTORY:
# - Initially configured with Cilium L2 announcements for LoadBalancer IPs
# - Discovered known bug in Cilium 1.17.x-1.18.x with ARP responses on virtualized interfaces
# - Applied workaround (manual IP + systemd service) for single-node clusters
# - Switched to MetalLB for proper multi-node LoadBalancer support
# - Cilium L2 announcements kept enabled for other features, MetalLB handles LoadBalancer IPs
#

set -e

export DEBIAN_FRONTEND=noninteractive
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Cilium HelmChartConfig
# ======================
# Full Cilium configuration with all features
# Cf https://github.com/rancher/rke2-charts/tree/main/charts/rke2-cilium/rke2-cilium/1.14.100
# Cf https://artifacthub.io/packages/helm/cilium/cilium
# Cf https://docs.cilium.io/en/stable/

echo "Configuring Cilium HelmChartConfig..."
mkdir -p /var/lib/rancher/rke2/server/manifests
cat <<'EOF' >/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true # https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/
    # k8sServiceHost: kubernetes.default.svc.cluster.local
    k8sServiceHost: 127.0.0.1 # IP dataplane (10.43.0.1) => kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}' => comment this line if you set kubeProxyReplacement=false
    k8sServicePort: 6443 # Port dataplane (443) => kubectl get svc kubernetes -n default -o jsonpath='{.spec.ports[0].port}' => comment this line if you set kubeProxyReplacement=false
    # routingMode: tunnel # https://docs.cilium.io/en/latest/network/concepts/routing/
    routingMode: native # https://docs.cilium.io/en/latest/network/concepts/routing/#native-routing
    autoDirectNodeRoutes: true # Si le réseau entre les nœuds inclut des passerelles (gateways), l'option autoDirectNodeRoutes peut ne pas fonctionner correctement, car elle est conçue pour des environnements où les nœuds sont directement connectés sur le même segment L2
    # directRoutingDevice: eth0
    ipv4NativeRoutingCIDR: 10.42.0.0/16 # https://docs.cilium.io/en/latest/network/clustermesh/clustermesh/#additional-requirements-for-native-routed-datapath-modes
    # ipv4NativeRoutingCIDR: 10.0.0.0/8
    tunnelProtocol: geneve # https://docs.cilium.io/en/latest/security/policy/caveats/#security-identity-for-n-s-service-traffic
    devices:
    - eth0
    # devices:
    # - ^eth[0-9]+
    # - eth1  # Alternative: use eth1 for dataplane separation
    externalIPs:
      enabled: true
    nodePort:
      enabled: false
    socketLB:
      enabled: true
    #   hostNamespaceOnly: true # (For Istio by example) https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#socket-loadbalancer-bypass-in-pod-namespace
    # sessionAffinity: ClientIP # https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/#session-affinity
    ingressController:
      enabled: false
      # default: true
      loadbalancerMode: shared  # Activation du mode "shared" pour le LoadBalancer, c'est à dire que plusieurs services peuvent utiliser le même LoadBalancer avec la même IP => https://docs.cilium.io/en/stable/network/servicemesh/ingress/ (Cf Annotations: ingress.cilium.io/loadbalancer-mode: shared|dedicated)
    # extraConfig:
    #   enable-envoy-config: true # https://docs.cilium.io/en/stable/network/servicemesh/l7-traffic-management/ (envoy traffic management feature without Ingress support (ingressController.enabled=false))
    l7Proxy: true
    loadBalancer:
      mode: dsr # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#direct-server-return-dsr
      dsrDispatch: geneve # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#direct-server-return-dsr-with-geneve
      algorithm: maglev # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#maglev-consistent-hashing
      serviceTopology: true # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#topology-aware-hints (service.kubernetes.io/topology-aware-hints: "auto"  # Active les hints / topology.kubernetes.io/zone / topology.kubernetes.io/region)
      acceleration: native # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#loadbalancer-nodeport-xdp-acceleration => liste des drivers des cartes compatibles https://docs.cilium.io/en/stable/reference-guides/bpf/progtypes/#xdp-drivers
      # l7: # CiliumHTTPRoute CRD
      #   algorithm: least_request # round_robin, least_request, random (cf https://docs.cilium.io/en/stable/network/servicemesh/envoy-load-balancing/#supported-annotations)
      #   backend: envoy # https://docs.cilium.io/en/stable/network/servicemesh/l7-traffic-management/
      #   # envoy: # https://docs.cilium.io/en/stable/helm-reference/ (use with service type LoadBalancer and can be configured with CRD CiliumHTTPRoute)
      #   #   idleTimeout: 60s  # Délai d'inactivité avant fermeture de la connexion
      #   #   maxRequestsPerConnection: 100  # Limite de requêtes par connexion
      #   #   retries: 3  # Nombre de tentatives de réessai
      #   #   requestTimeout: 60s  # Délai de timeout de requête
    # maglev:
    #   tableSize: 65521
    #   hashSeed: NXiDKpuSsIEgG92K
    gatewayAPI: # https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
      enabled: false # require kubeProxyReplacement=true
    # enableCiliumEndpointSlice: removed - deprecated in v1.16 and removed in v1.18
    ipMasqAgent:
      enabled: false
    bpf:
      preallocateMaps: true # Increase memory usage but can reduce latency
      masquerade: false # REQUIRED for Istio Ambient (BPF masq incompatible with Istio link-local IPs)
      autoDirectNodeRoutes: true
      hostLegacyRouting: false
    #   lbExternalClusterIP: true # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#external-access-to-clusterip-services
    # authentication: # https://docs.cilium.io/en/latest/network/servicemesh/mutual-authentication/mutual-authentication/ (https://youtu.be/tE9U1gNWzqs)
    #   mutual:
    #     port: 4250
    #     spire:
    #       enabled: true
    #       install:
    #         enabled: true
    #         namespace: cilium-spireauths
    # bandwidthManager: # https://docs.cilium.io/en/latest/network/kubernetes/bandwidth-manager/
    #   enabled: true
    #   bbr: true # https://docs.cilium.io/en/latest/network/kubernetes/bandwidth-manager/#bbr-for-pods
    operator:
      enabled: true
      replicas: 1
      prometheus:
        enabled: true
        serviceMonitor:
          # enabled: true # A activer une fois prometheus-stack installé
          labels:
            release: prometheus-stack
      # dashboards: # Cilium Operator dashboard (endpoints, IP allocation, reconciliation)
      #   enabled: true # A activer une fois prometheus-stack installé (via cilium-monitoring app)
      #   annotations:
      #     grafana_dashboard_folder: /tmp/dashboards/Cilium
    # encryption:
    #   enabled: true
    #   type: wireguard # https://docs.cilium.io/en/latest/security/network/encryption-wireguard
    #   # nodeEncryption: true # https://docs.cilium.io/en/latest/security/network/encryption-wireguard/#node-to-node-encryption-beta
    hostFirewall: # https://docs.cilium.io/en/stable/security/host-firewall/
      enabled: true
    policyEnforcementMode: default # https://docs.cilium.io/en/stable/security/policy/intro/
    ipam:
      mode: kubernetes
      # mode: cluster-pool
      # operator:
      #   clusterPoolIPv4MaskSize: 24
      #   clusterPoolIPv4PodCIDRList:
      #     - 10.42.0.0/16
    # k8s:
    #   requireIPv4PodCIDR: true # https://docs.cilium.io/en/latest/network/concepts/ipam/kubernetes/#configuration (require ipam.mode=kubernetes)
    #   requireIPv6PodCIDR: false
    # eni: # aws
    #   enabled: true
    cni:
      chainingMode: "none"
      exclusive: false # REQUIRED for Istio Ambient (CNI chaining with istio-cni)
    socketLB:
      hostNamespaceOnly: true # REQUIRED for Istio Ambient (prevents socket LB conflicts with ztunnel)

    # L2 Announcements - ENABLED for general L2 features
    # ===================================================
    # NOTE: LoadBalancer IP management is handled by MetalLB (installed via ArgoCD)
    # Cilium L2 announcements has known bugs with ARP responses on virtualized interfaces
    # when used for LoadBalancer IPAM. MetalLB provides more reliable LoadBalancer support.
    #
    # L2 announcements is kept enabled for other Cilium features, but LoadBalancer IPs
    # will be managed by MetalLB using CiliumLoadBalancerIPPool and CiliumL2AnnouncementPolicy
    l2announcements:
      enabled: true
      interface: eth1
      leaseDuration: 3s
      leaseRenewDeadline: 1s
      leaseRetryPeriod: 500ms
      # leaseDuration: 300s
      # leaseRenewDeadline: 60s
      # leaseRetryPeriod: 10s
    l2NeighDiscovery:
      enabled: true  # Enable L2 neighbor discovery to respond to ARP/NDP requests - https://github.com/cilium/cilium/issues/38223
      refreshPeriod: 30s
    # k8sClientRateLimit: # https://docs.cilium.io/en/latest/network/l2-announcements/#sizing-client-rate-limit
    #   qps: 10
    #   burst: 25

    # BGP - DISABLED (not needed for this setup)
    # bgp:
    #   enabled: true
    #   announce:
    #     loadbalancerIP: true
    #     podCIDR: true
    # bgpControlPlane:
    #   enabled: true

    # sctp:
    #   # -- Enable SCTP support. NOTE: Currently, SCTP support does not support rewriting ports or multihoming.
    #   enabled: true
    ipv4:
      enabled: true
    # enableIPv4BIGTCP: true # kernel >= 6.3 + harware compatibility (mlx4, mlx5, ice)
    ipv6:
      enabled: false
    enableIPv6BIGTCP: false

    # Hubble Observability
    # ====================
    hubble:
      enabled: true
      metrics:
        enableOpenMetrics: true
        serviceMonitor:
          # enabled: true # A activer une fois prometheus-stack installé
          labels:
            release: prometheus-stack
        enabled: # https://docs.cilium.io/en/stable/observability/metrics/#context-options
        # - policy:sourceContext=app|workload-name|pod|reserved-identity;destinationContext=app|workload-name|pod|dns|reserved-identity;labelsContext=source_namespace,destination_namespace
        - dns:query;ignoreAAAA
        # - dns  # Basic DNS metrics only - use dns:query;ignoreAAAA for detailed counters
        - drop
        - tcp
        # - "flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity"
        - flow
        - icmp
        # - http # deprecated
        - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity"
        # examplars=true will let us display OpenTelemetry trace points from application traces as an overlay on the Grafana graphs
        # labelsContext is set to add extra labels to metrics including source/destination IPs, source/destination namespaces, source/destination workloads, as well as traffic direction (ingress or egress)
        # sourceContext sets how the source label is built, in this case using the workload name when possible, or a reserved identity (e.g. world) otherwise
        # - "kafka:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity"
        # destinationContext does the same for destinations
        dashboards:
          enabled: true
          # namespace: ~
          label: grafana_dashboard
          labelValue: "1"
          annotations:
            grafana_folder: /tmp/dashboards/Cilium
      relay:
        enabled: true
        service:
          type: LoadBalancer
        prometheus:
          enabled: true
          serviceMonitor:
              # enabled: true # A activer une fois prometheus-stack installé
              labels:
                release: prometheus-stack
      ui:
        enabled: true
        # service:
        #   type: LoadBalancer
        replicas: 1
        # ingress:  # Géré par ArgoCD cilium-monitoring app (avec variables dynamiques)
        #   enabled: true
        #   # className: cilium
        #   hosts:
        #     - hubble.k8s.lan
        #   annotations:
        #     cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
        #   tls:
        #   - secretName: hubble-ui-tls
        #     hosts:
        #     - hubble.k8s.lan

    # Prometheus Metrics
    # ==================
    prometheus: # https://docs.cilium.io/en/stable/observability/metrics/
      enabled: true
      # Default port value (9090) needs to be changed since the RHEL cockpit also listens on this port.
      # port: 19090
      # Configure this serviceMonitor section AFTER Rancher Monitoring is enabled!
      serviceMonitor:
        # enabled: true # A activer une fois prometheus-stack installé
        labels:
          release: prometheus-stack
    # dashboard: # Deprecated - use 'dashboards' (plural) instead
    #   enabled: true
    #   # namespace: ~
    #   labelValue: "1"
    #   annotations:
    #     grafana_folder: /tmp/dashboards/Cilium
    # dashboards: # Cilium Agent dashboard (eBPF, kube-proxy replacement metrics)
    #   enabled: true # A activer une fois prometheus-stack installé (via cilium-monitoring app)
    #   annotations:
    #     grafana_dashboard_folder: /tmp/dashboards/Cilium

    # Envoy Proxy
    # ===========
    envoy:
      enabled: true # Install Envoy as DaemonSet instead of Pod (https://docs.cilium.io/en/stable/security/network/proxy/envoy/)
      prometheus:
        enabled: true
        serviceMonitor:
          # enabled: true # A activer une fois prometheus-stack installé
          labels:
            release: prometheus-stack

    # Cluster Mesh (disabled for single cluster)
    # ===========================================
    # clustermesh:
    #   apiserver:
    #     metrics:
    #       kvstoremesh:
    #         enabled: true
    #       etcd:
    #         enabled: true
    #       serviceMonitor:
    #         # enabled: true # A activer une fois prometheus-stack installé
    #         labels:
    #           release: prometheus-stack
EOF

echo "✓ Cilium HelmChartConfig created"
echo "  - kube-proxy replacement: enabled"
echo "  - Routing mode: native"
echo "  - Network interface: eth1"
echo "  - L2 announcements: ENABLED (for general L2 features)"
echo "  - LoadBalancer IPAM: Handled by MetalLB (via ArgoCD)"
echo "  - Hubble observability: enabled"
echo "  - Prometheus metrics: enabled"
echo "  - Host firewall: enabled"
echo ""
echo "✓ Cilium CNI configuration completed successfully"

# ==============================================================================
# ARCHIVED CODE - Cilium LoadBalancer IPAM with workaround (COMMENTED OUT)
# ==============================================================================
# This section contains the previous implementation using Cilium LoadBalancer IPAM
# with L2 announcements and ARP workaround for virtualized interfaces.
# It has been replaced by MetalLB due to known bugs in Cilium 1.17.x-1.18.x.
# Kept for reference and potential future use when bugs are fixed.
# ==============================================================================

: <<'ARCHIVED_LOADBALANCER_IPAM'

# Wait for Kubernetes API to be ready
echo "Waiting for Kubernetes API to be available..."
while ! kubectl get nodes &>/dev/null; do
  echo "Waiting for Kubernetes API..."
  sleep 5
done
echo "✓ Kubernetes API is ready"

# Cilium LoadBalancer IP Pools
# =============================
# Configure IP pools for LoadBalancer services
# - apiserver pool: dedicated IP (192.168.121.200) for Kubernetes API
# - default pool: range of IPs (192.168.121.201-250) for other services
# Cf https://docs.cilium.io/en/stable/network/lb-ipam/

echo "Creating Cilium LoadBalancer IP pools..."
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "apiserver"
spec:
  blocks:
  - cidr: "192.168.121.200/32"
  serviceSelector:
    matchExpressions:
      - {key: io.kubernetes.service.name, operator: In, values: [kubernetes]}
      - {key: io.kubernetes.service.namespace, operator: In, values: [default]}
---
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "default"
spec:
  blocks:
  - cidr: "192.168.121.201/32"
  - cidr: "192.168.121.202/32"
  - start: "192.168.121.203"
    stop: "192.168.121.250"
EOF

echo "✓ IP pools created (apiserver: 192.168.121.200, default: 192.168.121.201-250)"

# Cilium L2 Announcement Policy
# ==============================
# Configure L2 announcements to make LoadBalancer IPs accessible on the local network
# Cf https://docs.cilium.io/en/stable/network/l2-announcements/

echo "Creating Cilium L2 Announcement Policy..."
cat <<EOF | kubectl apply -f -
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: l2-policy
spec:
  serviceSelector:
    matchLabels: {}
  interfaces:
  - eth1
  externalIPs: true
  loadBalancerIPs: true
EOF

echo "✓ L2 Announcement Policy created"

# Configure Kubernetes API as LoadBalancer
# =========================================
# Change the kubernetes service type from ClusterIP to LoadBalancer
# This will assign it the IP from the "apiserver" pool (192.168.121.200)

echo "Configuring Kubernetes API service as LoadBalancer..."
kubectl patch svc kubernetes -n default -p '{"spec": {"type": "LoadBalancer"}}'

# Wait for LoadBalancer IP assignment
echo "Waiting for LoadBalancer IP to be assigned..."
while true; do
  API_LB_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [ -n "$API_LB_IP" ]; then
    echo "LoadBalancer IP assigned: $API_LB_IP"
    break
  fi
  sleep 2
done

# Workaround for Cilium L2 Announcements ARP response bug
# ========================================================
# Problem: Cilium L2 announcements doesn't respond to ARP requests on virtualized interfaces (virtio/libvirt/KVM)
# Even though:
#   - EnableL2Announcements is true
#   - L2 leases are successfully acquired
#   - l2NeighDiscovery is enabled
#   - XDP programs are loaded on eth1
#   - The l2-responder eBPF module exists
# The kernel never sends ARP responses for the LoadBalancer IP, resulting in "Destination Host Unreachable"
#
# Root Cause: Known bug in Cilium 1.17.x - 1.18.x (as of October 2025)
#   - GitHub Issues: #38223, #37959, #35972
#   - Error in logs: "Error(s) while reconciling l2 responder map"
#   - The l2-responder eBPF module fails to properly handle ARP requests
#
# Solution: Add the LoadBalancer IP directly to the network interface
# This allows the Linux kernel to handle ARP responses natively, bypassing the broken eBPF l2-responder
# The IP is added with /32 netmask to avoid routing conflicts
# The '|| true' prevents script failure if the IP already exists
#
# This workaround is standard practice in the Cilium community for this known issue
# It can be removed once Cilium fixes the l2-responder ARP handling bug
#
# NOTE: This workaround only works for single-node clusters. For multi-node clusters, use MetalLB.

echo "Applying workaround for Cilium L2 ARP bug..."
ip addr add ${API_LB_IP}/32 dev eth1 || true
echo "✓ Added LoadBalancer IP ${API_LB_IP} to eth1 (workaround for Cilium L2 ARP bug)"

# Create systemd service to make the workaround persistent across reboots
echo "Creating systemd service for persistent workaround..."
cat <<SYSTEMD_EOF > /etc/systemd/system/cilium-l2-workaround.service
[Unit]
Description=Cilium L2 ARP Workaround - Add LoadBalancer IP to eth1
After=network-online.target
Wants=network-online.target
Before=rke2-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip addr add ${API_LB_IP}/32 dev eth1 || true'
ExecStop=/bin/sh -c 'ip addr del ${API_LB_IP}/32 dev eth1 || true'

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable cilium-l2-workaround.service
systemctl start cilium-l2-workaround.service
echo "✓ Created and enabled cilium-l2-workaround.service for persistence across reboots"

echo "✓ Cilium LoadBalancer IPAM configuration completed successfully"

ARCHIVED_LOADBALANCER_IPAM

# End of archived LoadBalancer IPAM code
