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
# Gateway API Provider Selection (GATEWAY_API_PROVIDER environment variable)
# =============================================================================
# GATEWAY_API_PROVIDER=cilium: Cilium Gateway API controller
#   - Enables gatewayAPI.enabled=true in Cilium config
#   - GatewayClass "cilium" normally created by Helm chart (gatewayClass.create="auto")
#   - At first install, CRDs don't exist yet → Helm skips GatewayClass creation
#   - deploy-applicationsets.sh creates the GatewayClass manually after CRDs arrive
#   - On future RKE2 upgrades, Cilium Helm adopts the existing GatewayClass
#   - Requires kubeProxyReplacement=true (already enabled)
#
# GATEWAY_API_PROVIDER=<other>: External Gateway API controller (istio, traefik, etc.)
#   - Cilium gatewayAPI.enabled=false (default)
#   - Gateway API handled by external controller
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
GATEWAY_API_PROVIDER="${GATEWAY_API_PROVIDER:-none}"

# Determine Gateway API setting based on provider
# Only enable Cilium Gateway API when provider is explicitly "cilium"
# NOTE: This script only runs when CNI is Cilium (RKE2 default), so no CNI check needed here
# The Cilium HelmChartConfig is only applied when Cilium CNI is being used
if [ "$GATEWAY_API_PROVIDER" = "cilium" ]; then
  GATEWAY_API_ENABLED="true"
  echo "Gateway API Provider: Cilium (gatewayAPI.enabled=true)"
else
  GATEWAY_API_ENABLED="false"
  echo "Gateway API Provider: $GATEWAY_API_PROVIDER (Cilium gatewayAPI DISABLED)"
fi

# Determine encryption settings based on environment variables (from install_master.sh)
CILIUM_ENCRYPTION_ENABLED="${CILIUM_ENCRYPTION_ENABLED:-false}"
CILIUM_ENCRYPTION_TYPE="${CILIUM_ENCRYPTION_TYPE:-wireguard}"
CILIUM_NODE_ENCRYPTION="${CILIUM_NODE_ENCRYPTION:-true}"
CILIUM_STRICT_MODE="${CILIUM_STRICT_MODE:-false}"

if [ "$CILIUM_ENCRYPTION_ENABLED" = "true" ]; then
  ENCRYPTION_BLOCK="    encryption:
      enabled: true
      type: ${CILIUM_ENCRYPTION_TYPE}
      nodeEncryption: ${CILIUM_NODE_ENCRYPTION}"
  if [ "$CILIUM_STRICT_MODE" = "true" ]; then
    ENCRYPTION_BLOCK="${ENCRYPTION_BLOCK}
      strictMode:
        enabled: true
        cidr: 10.42.0.0/16
        allowRemoteNodeIdentities: true"
  fi
  echo "Cilium Encryption: ENABLED (type=${CILIUM_ENCRYPTION_TYPE}, nodeEncryption=${CILIUM_NODE_ENCRYPTION}, strictMode=${CILIUM_STRICT_MODE})"
else
  ENCRYPTION_BLOCK="    # encryption: disabled (features.cilium.encryption.enabled=false)"
  echo "Cilium Encryption: DISABLED"
fi

# Calculate MTU based on encapsulation overhead
# Ref: https://docs.cilium.io/en/stable/operations/performance/tuning/
# Overheads:
#   - WireGuard: 80 B (outer IP 20 + UDP 8 + WireGuard header 32 + padding ~20)
#   - IPsec (ESP): 64 B (ESP header + IV + padding + ICV)
#   - VXLAN: 50 B (outer Ethernet 14 + outer IP 20 + UDP 8 + VXLAN 8)
#   - Geneve: 50 B (same structure as VXLAN)
# Note: routingMode=native → no tunnel overhead (tunnelProtocol only used for DSR dispatch)
#       routingMode=tunnel → add VXLAN/Geneve overhead
BASE_MTU=1500
MTU_OVERHEAD=0

# Tunnel overhead (only applies when routingMode=tunnel)
# Currently hardcoded to native, but calculated for future-proofing
ROUTING_MODE="native"
if [ "$ROUTING_MODE" = "tunnel" ]; then
  MTU_OVERHEAD=$((MTU_OVERHEAD + 50))
fi

# Encryption overhead
if [ "$CILIUM_ENCRYPTION_ENABLED" = "true" ]; then
  case "$CILIUM_ENCRYPTION_TYPE" in
    wireguard) MTU_OVERHEAD=$((MTU_OVERHEAD + 80)) ;;
    ipsec)     MTU_OVERHEAD=$((MTU_OVERHEAD + 64)) ;;
  esac
fi

if [ "$MTU_OVERHEAD" -gt 0 ]; then
  CILIUM_MTU=$((BASE_MTU - MTU_OVERHEAD))
  MTU_YAML="    MTU: ${CILIUM_MTU}"
  echo "Cilium MTU: ${CILIUM_MTU} (base=${BASE_MTU} - overhead=${MTU_OVERHEAD})"
else
  MTU_YAML="    # MTU: auto (no encapsulation overhead)"
  echo "Cilium MTU: auto (no encapsulation overhead)"
fi

# Determine mutual authentication settings (SPIFFE/SPIRE)
CILIUM_MUTUAL_AUTH="${CILIUM_MUTUAL_AUTH:-false}"
CILIUM_MUTUAL_AUTH_PORT="${CILIUM_MUTUAL_AUTH_PORT:-4250}"

if [ "$CILIUM_MUTUAL_AUTH" = "true" ]; then
  # dataStorage disabled at bootstrap: storage provider (Rook/Longhorn) is not yet
  # deployed. Migration to PVC happens post-deployment in deploy-applicationsets.sh
  # when storage is ready (features.cilium.mutualAuth.spire.dataStorage.enabled=true).
  # emptyDir is safe: SPIRE re-issues all identities on restart (~30s re-negotiation).
  AUTH_BLOCK="    authentication:
      enabled: true
      mutual:
        port: ${CILIUM_MUTUAL_AUTH_PORT}
        spire:
          enabled: true
          install:
            enabled: true
            namespace: cilium-spire
            server:
              dataStorage:
                enabled: false
              podSecurityContext:
                runAsUser: 0
                runAsGroup: 0
            agent:
              podSecurityContext:
                runAsUser: 0
                runAsGroup: 0"
  echo "Cilium Mutual Auth: ENABLED (SPIFFE/SPIRE on port ${CILIUM_MUTUAL_AUTH_PORT})"
else
  AUTH_BLOCK="    # authentication: disabled (features.cilium.mutualAuth.enabled=false)"
  echo "Cilium Mutual Auth: DISABLED"
fi

# Determine Istio Ambient compatibility settings
# When Istio service mesh is active, Cilium must adjust several settings:
# - bpf.masquerade=false: BPF masq incompatible with Istio link-local IPs
# - cni.exclusive=false: Allow istio-cni to chain with Cilium
# - socketLB.hostNamespaceOnly=true: Prevent conflicts with ztunnel
SERVICE_MESH_ENABLED="${SERVICE_MESH_ENABLED:-false}"
SERVICE_MESH_PROVIDER="${SERVICE_MESH_PROVIDER:-none}"

if [ "$SERVICE_MESH_ENABLED" = "true" ] && [ "$SERVICE_MESH_PROVIDER" = "istio" ]; then
  BPF_MASQUERADE="false"
  CNI_EXCLUSIVE="false"
  SOCKET_LB_HOST_NS_ONLY="true"
  echo "Service Mesh: Istio (bpf.masquerade=false, cni.exclusive=false, socketLB.hostNamespaceOnly=true)"
else
  BPF_MASQUERADE="true"
  CNI_EXCLUSIVE="true"
  SOCKET_LB_HOST_NS_ONLY="false"
fi

# Determine container runtime sandbox compatibility settings
# Kata Containers / gVisor / KubeVirt require socketLB.hostNamespaceOnly=true
# The socket-level LB intercepts connect()/sendmsg() via eBPF, but with Kata
# these syscalls happen in the VM kernel (not the host kernel), making socket LB
# ineffective. Setting hostNamespaceOnly=true falls back to tc LB at the veth.
# Ref: https://docs.cilium.io/en/stable/network/kubernetes/kata/
# Ref: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
CONTAINER_RUNTIME_ENABLED="${CONTAINER_RUNTIME_ENABLED:-false}"
CONTAINER_RUNTIME_PROVIDER="${CONTAINER_RUNTIME_PROVIDER:-none}"

if [ "$CONTAINER_RUNTIME_ENABLED" = "true" ] && [ "$CONTAINER_RUNTIME_PROVIDER" = "kata" ]; then
  SOCKET_LB_HOST_NS_ONLY="true"
  echo "Container Runtime: Kata Containers (socketLB.hostNamespaceOnly=true)"
fi

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

# Pre-create cilium-spire namespace with privileged PodSecurity labels
# SPIRE requires hostNetwork, hostPID, hostPath, allowPrivilegeEscalation
# which are blocked by the "restricted" PodSecurity profile
if [ "$CILIUM_MUTUAL_AUTH" = "true" ]; then
  cat <<EOF >/var/lib/rancher/rke2/server/manifests/cilium-spire-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cilium-spire
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: rke2-cilium
    meta.helm.sh/release-namespace: kube-system
EOF
  echo "✓ cilium-spire namespace manifest created (PodSecurity: privileged, Helm-adopted)"
fi
cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true # https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/
${MTU_YAML}
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
      hostNamespaceOnly: ${SOCKET_LB_HOST_NS_ONLY} # true when Istio Ambient (prevents conflicts with ztunnel)
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
    # Gateway API - Controlled by GATEWAY_API_PROVIDER
    # =============================================
    # GATEWAY_API_PROVIDER=cilium: ENABLED (Cilium handles Gateway API)
    # GATEWAY_API_PROVIDER=<other>: DISABLED (external controller like istio/traefik)
    gatewayAPI: # https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
      enabled: ${GATEWAY_API_ENABLED} # require kubeProxyReplacement=true
      enableAlpn: true # Required for gRPC over TLS (GRPCRoute)
      gatewayClass:
        create: "auto" # "auto" = create only if CRDs exist at Helm install time (see deploy-applicationsets.sh for re-reconciliation)
    # enableCiliumEndpointSlice: removed - deprecated in v1.16 and removed in v1.18
    ipMasqAgent:
      enabled: false
    bpf:
      preallocateMaps: true # Increase memory usage but can reduce latency
      masquerade: ${BPF_MASQUERADE} # false when Istio Ambient (BPF masq incompatible with link-local IPs)
      autoDirectNodeRoutes: true
      hostLegacyRouting: false
      lbExternalClusterIP: true # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#external-access-to-clusterip-services (hairpin NAT for pods accessing LoadBalancer IPs)
${AUTH_BLOCK}
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
${ENCRYPTION_BLOCK}
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
      exclusive: ${CNI_EXCLUSIVE} # false when Istio Ambient (CNI chaining with istio-cni)

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
if [ "$GATEWAY_API_PROVIDER" = "cilium" ]; then
  echo "  - Gateway API: ENABLED (Cilium controller)"
else
  echo "  - Gateway API: DISABLED (using $GATEWAY_API_PROVIDER)"
fi
echo "  - Hubble observability: enabled"
echo "  - Prometheus metrics: enabled"
echo "  - Host firewall: enabled"
if [ "$CILIUM_ENCRYPTION_ENABLED" = "true" ]; then
  echo "  - Encryption: ${CILIUM_ENCRYPTION_TYPE} (nodeEncryption=${CILIUM_NODE_ENCRYPTION}, strictMode=${CILIUM_STRICT_MODE})"
fi
if [ "$CILIUM_MUTUAL_AUTH" = "true" ]; then
  echo "  - Mutual Authentication: SPIFFE/SPIRE (port=${CILIUM_MUTUAL_AUTH_PORT})"
fi
echo ""
echo "✓ Cilium CNI configuration completed successfully"
