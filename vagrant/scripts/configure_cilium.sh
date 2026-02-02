#!/usr/bin/env bash
#
# Configure Cilium CNI for RKE2 cluster
# This script configures Cilium with full CNI settings
#
# LoadBalancer Provider Selection (LB_PROVIDER environment variable)
# =============================================================================
# LB_PROVIDER=metallb (default): MetalLB handles LoadBalancer IPs
#   - Cilium L2 announcements DISABLED to avoid conflict
#   - MetalLB L2 mode provides stable ARP responses
#
# LB_PROVIDER=cilium: Cilium LB-IPAM with L2 announcements
#   - Cilium L2 announcements ENABLED
#   - Uses CiliumLoadBalancerIPPool and CiliumL2AnnouncementPolicy (via ArgoCD)
#   - Known ARP bugs on virtualized interfaces in Cilium 1.17.x-1.18.x
#
# HISTORY:
# - Initially configured with Cilium L2 announcements for LoadBalancer IPs
# - Discovered known bug in Cilium 1.17.x-1.18.x with ARP responses on virtualized interfaces
# - Applied workaround (manual IP + systemd service) for single-node clusters
# - Switched to MetalLB for proper multi-node LoadBalancer support
# - Now configurable via LB_PROVIDER environment variable
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

# Determine L2 announcements setting based on LoadBalancer provider
# Only enable Cilium L2 announcements when provider is explicitly "cilium"
# For any other provider (metallb, loxilb, klipper, none, etc.), Cilium L2 is disabled
LB_PROVIDER="${LB_PROVIDER:-metallb}"
CNI_MULTUS_ENABLED="${CNI_MULTUS_ENABLED:-false}"

if [ "$LB_PROVIDER" = "cilium" ]; then
  L2_ANNOUNCEMENTS_ENABLED="true"
  # Both interfaces for Cilium L2 announcements
  CILIUM_DEVICES_YAML=$'    - eth0\n    - eth1'
  echo "LoadBalancer Provider: Cilium LB-IPAM (L2 announcements ENABLED)"
elif [ "$LB_PROVIDER" = "loxilb" ]; then
  L2_ANNOUNCEMENTS_ENABLED="false"
  # LoxiLB with Multus/macvlan: exclude eth1 to prevent Cilium eBPF hooks from
  # intercepting traffic before it reaches LoxiLB on the macvlan interface
  CILIUM_DEVICES_YAML=$'    - eth0'
  echo "LoadBalancer Provider: LoxiLB (Cilium L2 DISABLED, eth1 excluded from Cilium devices)"
elif [ "$LB_PROVIDER" = "klipper" ]; then
  L2_ANNOUNCEMENTS_ENABLED="false"
  CILIUM_DEVICES_YAML=$'    - eth0\n    - eth1'
  echo "LoadBalancer Provider: Klipper/ServiceLB (Cilium L2 announcements DISABLED, uses node IPs)"
else
  L2_ANNOUNCEMENTS_ENABLED="false"
  CILIUM_DEVICES_YAML=$'    - eth0\n    - eth1'
  echo "LoadBalancer Provider: $LB_PROVIDER (Cilium L2 announcements DISABLED)"
fi

# CNI chaining mode info
if [ "$CNI_MULTUS_ENABLED" = "true" ]; then
  echo "CNI Chaining: enabled (Multus mode - secondary interfaces for LoxiLB)"
fi

echo "Configuring Cilium HelmChartConfig..."
mkdir -p /var/lib/rancher/rke2/server/manifests
cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
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
    # Devices managed by Cilium eBPF hooks
    # - For loxilb: only eth0 (eth1 excluded to allow macvlan traffic to reach LoxiLB)
    # - For others: eth0 + eth1 (required for kube-vip and L2 announcements)
    devices:
${CILIUM_DEVICES_YAML}
    # Alternative: regex pattern for all eth interfaces
    # devices:
    # - ^eth[0-9]+
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
      lbExternalClusterIP: true # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#external-access-to-clusterip-services (hairpin NAT for pods accessing LoadBalancer IPs)
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
      #   enabled: true # A activer une fois prometheus-stack installé (via cilium app)
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

    # L2 Announcements - Controlled by LB_PROVIDER
    # =============================================
    # LB_PROVIDER=metallb: DISABLED (MetalLB handles L2 announcements)
    # LB_PROVIDER=cilium: ENABLED (Cilium handles L2 announcements + LB-IPAM)
    #
    # WARNING: Having both MetalLB and Cilium L2 enabled causes conflicts!
    l2announcements:
      enabled: ${L2_ANNOUNCEMENTS_ENABLED}
      interface: eth1
      leaseDuration: 3s
      leaseRenewDeadline: 1s
      leaseRetryPeriod: 500ms
      # leaseDuration: 300s
      # leaseRenewDeadline: 60s
      # leaseRetryPeriod: 10s
    l2NeighDiscovery:
      enabled: ${L2_ANNOUNCEMENTS_ENABLED}  # Match l2announcements setting
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
          type: ClusterIP  # Exposed via HTTPRoute (hubble.k8s.lan)
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
        # ingress:  # Géré par ArgoCD cilium app (avec variables dynamiques)
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
    #   enabled: true # A activer une fois prometheus-stack installé (via cilium app)
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
if [ "$LB_PROVIDER" = "cilium" ]; then
  echo "  - L2 announcements: ENABLED (Cilium LB-IPAM mode)"
  echo "  - LoadBalancer IPAM: Cilium (CiliumLoadBalancerIPPool via ArgoCD)"
else
  echo "  - L2 announcements: DISABLED ($LB_PROVIDER mode)"
  echo "  - LoadBalancer IPAM: $LB_PROVIDER (via ArgoCD)"
fi
echo "  - Hubble observability: enabled"
echo "  - Prometheus metrics: enabled"
echo "  - Host firewall: enabled"
echo ""
echo "✓ Cilium CNI configuration completed successfully"
