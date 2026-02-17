#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Determine script and project directories (agnostic of mount point)
# When run via Vagrant provisioner, BASH_SOURCE may not work correctly
if [ -f "/vagrant/vagrant/scripts/RKE2_ENV.sh" ]; then
  SCRIPT_DIR="/vagrant/vagrant/scripts"
  PROJECT_ROOT="/vagrant"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

. "$SCRIPT_DIR/RKE2_ENV.sh"
# export INSTALL_RKE2_VERSION=v1.24.8+rke2r1
# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

# Verify yq (mikefarah) is available (installed by install_common.sh)
if ! command -v yq &>/dev/null || ! yq --version 2>&1 | grep -q "mikefarah"; then
  echo "ERROR: yq (mikefarah) is required but not found. Ensure install_common.sh ran first."
  echo "Note: The apt 'yq' package (kislyuk/yq) is NOT compatible."
  exit 1
fi

# Helper: read YAML value with yq, returns empty string if null/missing
yq_read() {
  local result
  result=$(yq eval "$1" "$2" 2>/dev/null)
  [ "$result" = "null" ] && echo "" || echo "$result"
}

curl -sfL https://get.rke2.io | sh -
mkdir -p /etc/rancher/rke2

# Read CIS configuration from ArgoCD config (single source of truth)
ARGOCD_CONFIG_FILE="$PROJECT_ROOT/deploy/argocd/config/config.yaml"
CIS_ENABLED=$(yq_read '.rke2.cis.enabled' "$ARGOCD_CONFIG_FILE")
CIS_PROFILE=$(yq_read '.rke2.cis.profile' "$ARGOCD_CONFIG_FILE")

# CIS Hardening: Apply required kernel parameters and create etcd user if enabled
# https://docs.rke2.io/security/hardening_guide
if [ "$CIS_ENABLED" = "true" ]; then
  echo "CIS Hardening enabled with profile: ${CIS_PROFILE:-cis}"

  # Create etcd user/group (required by CIS profile)
  if ! id etcd &>/dev/null; then
    useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
  fi

  # Apply CIS sysctl parameters
  if [ -f /usr/local/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  elif [ -f /usr/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  fi
  systemctl restart systemd-sysctl

  # Read CIS hardening options from config (with defaults)
  DENY_SERVICE_EXTERNAL_IPS=$(yq_read '.rke2.cis.hardening.admissionPlugins.denyServiceExternalIPs' "$ARGOCD_CONFIG_FILE")
  EVENT_RATE_LIMIT=$(yq_read '.rke2.cis.hardening.admissionPlugins.eventRateLimit' "$ARGOCD_CONFIG_FILE")
  ALWAYS_PULL_IMAGES=$(yq_read '.rke2.cis.hardening.admissionPlugins.alwaysPullImages' "$ARGOCD_CONFIG_FILE")
  REQUEST_TIMEOUT=$(yq_read '.rke2.cis.hardening.apiServer.requestTimeout' "$ARGOCD_CONFIG_FILE")
  SERVICE_ACCOUNT_LOOKUP=$(yq_read '.rke2.cis.hardening.apiServer.serviceAccountLookup' "$ARGOCD_CONFIG_FILE")
  EVENT_QPS=$(yq_read '.rke2.cis.hardening.kubelet.eventQps' "$ARGOCD_CONFIG_FILE")
  POD_MAX_PIDS=$(yq_read '.rke2.cis.hardening.kubelet.podMaxPids' "$ARGOCD_CONFIG_FILE")
  ANONYMOUS_AUTH=$(yq_read '.rke2.cis.hardening.kubelet.anonymousAuth' "$ARGOCD_CONFIG_FILE")
  MAKE_IPTABLES_UTIL_CHAINS=$(yq_read '.rke2.cis.hardening.kubelet.makeIptablesUtilChains' "$ARGOCD_CONFIG_FILE")
  PROTECT_KERNEL_DEFAULTS=$(yq_read '.rke2.cis.hardening.kubelet.protectKernelDefaults' "$ARGOCD_CONFIG_FILE")
  FIX_ETCD_OWNERSHIP=$(yq_read '.rke2.cis.hardening.filePermissions.fixEtcdOwnership' "$ARGOCD_CONFIG_FILE")
  FIX_PKI_PERMISSIONS=$(yq_read '.rke2.cis.hardening.filePermissions.fixPkiPermissions' "$ARGOCD_CONFIG_FILE")

  # Set defaults if not specified
  DENY_SERVICE_EXTERNAL_IPS=${DENY_SERVICE_EXTERNAL_IPS:-true}
  EVENT_RATE_LIMIT=${EVENT_RATE_LIMIT:-true}
  ALWAYS_PULL_IMAGES=${ALWAYS_PULL_IMAGES:-false}
  REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-60s}
  SERVICE_ACCOUNT_LOOKUP=${SERVICE_ACCOUNT_LOOKUP:-true}
  EVENT_QPS=${EVENT_QPS:-5}
  POD_MAX_PIDS=${POD_MAX_PIDS:-4096}
  ANONYMOUS_AUTH=${ANONYMOUS_AUTH:-false}
  MAKE_IPTABLES_UTIL_CHAINS=${MAKE_IPTABLES_UTIL_CHAINS:-true}
  PROTECT_KERNEL_DEFAULTS=${PROTECT_KERNEL_DEFAULTS:-true}
  FIX_ETCD_OWNERSHIP=${FIX_ETCD_OWNERSHIP:-true}
  FIX_PKI_PERMISSIONS=${FIX_PKI_PERMISSIONS:-true}
fi
# test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
# echo "RKE2_CNI=calico" >> /usr/local/lib/systemd/system/rke2-server.env
# echo "RKE2_CNI=calico" >> "${CONFIG_PATH}"

# Read CNI configuration from ArgoCD config (using yq for reliable YAML parsing)
CNI_PRIMARY=$(yq_read '.cni.primary' "$ARGOCD_CONFIG_FILE")
CNI_PRIMARY=${CNI_PRIMARY:-cilium}
CNI_MULTUS_ENABLED=$(yq_read '.cni.multus.enabled' "$ARGOCD_CONFIG_FILE")
CNI_MULTUS_ENABLED=${CNI_MULTUS_ENABLED:-false}
CNI_WHEREABOUTS_ENABLED=$(yq_read '.cni.multus.whereabouts' "$ARGOCD_CONFIG_FILE")
CNI_WHEREABOUTS_ENABLED=${CNI_WHEREABOUTS_ENABLED:-true}
LB_PROVIDER_CONFIG=$(yq_read '.features.loadBalancer.provider' "$ARGOCD_CONFIG_FILE")
LB_PROVIDER_CONFIG=${LB_PROVIDER_CONFIG:-metallb}
export CNI_MULTUS_ENABLED

# Validate CNI/provider compatibility
if [ "$CNI_PRIMARY" = "cilium" ] && [ "$LB_PROVIDER_CONFIG" = "loxilb" ] && [ "$CNI_MULTUS_ENABLED" != "true" ]; then
  echo "============================================================"
  echo "ERREUR: LoxiLB nécessite Multus CNI pour fonctionner avec Cilium"
  echo "============================================================"
  echo "LoxiLB et Cilium utilisent tous deux des hooks eBPF/XDP"
  echo "et entrent en conflit sans isolation via Multus."
  echo ""
  echo "Solution: Activer Multus dans config.yaml:"
  echo "  cni:"
  echo "    multus:"
  echo "      enabled: true"
  echo ""
  echo "Puis relancer: make vagrant-dev-destroy && make dev-full"
  echo "============================================================"
  exit 1
fi

if [ "$CNI_MULTUS_ENABLED" = "true" ]; then
  echo "CNI: Multus + $CNI_PRIMARY (multi-network enabled)"
  echo "  - Whereabouts IPAM: $CNI_WHEREABOUTS_ENABLED"
else
  echo "CNI: $CNI_PRIMARY (single network)"
fi

echo "disable:
- rke2-ingress-nginx
$([ "$CNI_PRIMARY" = "cilium" ] && echo "- rke2-kube-proxy # Cilium eBPF replaces kube-proxy at bootstrap")
- rke2-canal # disable default CNI (using $CNI_PRIMARY instead)
# - rke2-metrics-server
# - rke2-ingress-nginx
# - rke2-coredns
# disable: [rke2-ingress-nginx, rke2-coredns]
$([ "$CNI_PRIMARY" = "cilium" ] && echo 'disable-kube-proxy: true # Cilium eBPF replaces kube-proxy' || echo '# kube-proxy kept active for Calico BPF bootstrap (Calico takes over once running)')
write-kubeconfig-mode: "0644"
tls-san:
- k8s-api.k8s.lan
- 192.168.121.200
# debug:true
kube-controller-manager-arg:
# - address=0.0.0.0
- bind-address=0.0.0.0
# kube-proxy-arg:
# - address=0.0.0.0
# - metrics-bind-address=0.0.0.0
# kube-apiserver-arg:
#   - feature-gates=TopologyAwareHints=true,JobTrackingWithFinalizers=true
kube-scheduler-arg:
- bind-address=0.0.0.0
etcd-expose-metrics: true
# etcd-snapshot-name: xxx
# etcd-snapshot-schedule-cron: */22****
# etcd-snapshot-retention: 7
# etcd-s3: true
# etcd-s3-bucket: minio
# etcd-s3-region: us-north-9
# etcd-s3-endpoint: minio.k8s.lan
# etcd-s3-access-key: **************************
# etcd-s3-secret-key: **************************" \
>>/etc/rancher/rke2/config.yaml

# Configure CNI (Cilium/Calico, with optional Multus)
if [ "$CNI_MULTUS_ENABLED" = "true" ]; then
  echo "cni:" >> /etc/rancher/rke2/config.yaml
  echo "- multus" >> /etc/rancher/rke2/config.yaml
  echo "- $CNI_PRIMARY" >> /etc/rancher/rke2/config.yaml

  # Create HelmChartConfig for Multus with Whereabouts IPAM
  mkdir -p /var/lib/rancher/rke2/server/manifests
  cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-multus-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-multus
  namespace: kube-system
spec:
  valuesContent: |-
    rke2-whereabouts:
      enabled: ${CNI_WHEREABOUTS_ENABLED}
EOF
  echo "✓ Multus HelmChartConfig created (Whereabouts IPAM: $CNI_WHEREABOUTS_ENABLED)"
else
  echo "cni:" >> /etc/rancher/rke2/config.yaml
  echo "- $CNI_PRIMARY" >> /etc/rancher/rke2/config.yaml
fi

# Add CIS profile if enabled in config.yaml
if [ "$CIS_ENABLED" = "true" ]; then
  echo "profile: ${CIS_PROFILE:-cis}" >> /etc/rancher/rke2/config.yaml

  # Build admission plugins list (K.1.2.3, K.1.2.9)
  # RKE2 CIS profile adds --enable-admission-plugins=NodeRestriction
  # Since kube-apiserver takes only the LAST value when flag is repeated,
  # we must include NodeRestriction in our list to avoid overwriting it
  ADMISSION_PLUGINS="NodeRestriction"
  if [ "$DENY_SERVICE_EXTERNAL_IPS" = "true" ]; then
    ADMISSION_PLUGINS="${ADMISSION_PLUGINS},DenyServiceExternalIPs"
  fi
  if [ "$EVENT_RATE_LIMIT" = "true" ]; then
    ADMISSION_PLUGINS="${ADMISSION_PLUGINS},EventRateLimit"
  fi
  if [ "$ALWAYS_PULL_IMAGES" = "true" ]; then
    ADMISSION_PLUGINS="${ADMISSION_PLUGINS},AlwaysPullImages"
  fi

  # Add kube-apiserver args for CIS hardening
  # Note: RKE2 CIS profile adds --admission-control-config-file=/etc/rancher/rke2/rke2-pss.yaml
  # When EventRateLimit is enabled, we use our own config file (kube-apiserver uses the LAST value)
  echo "kube-apiserver-arg:" >> /etc/rancher/rke2/config.yaml
  echo "- enable-admission-plugins=$ADMISSION_PLUGINS" >> /etc/rancher/rke2/config.yaml
  echo "- request-timeout=$REQUEST_TIMEOUT" >> /etc/rancher/rke2/config.yaml
  echo "- service-account-lookup=$SERVICE_ACCOUNT_LOOKUP" >> /etc/rancher/rke2/config.yaml

  # EventRateLimit requires admission control config
  # Create our own file (not rke2-pss.yaml which RKE2 overwrites) with PodSecurity + EventRateLimit
  # kube-apiserver uses the LAST --admission-control-config-file argument, so ours takes precedence
  if [ "$EVENT_RATE_LIMIT" = "true" ]; then
    ADMISSION_CONFIG_FILE="/etc/rancher/rke2/admission-control-config.yaml"
    echo "- admission-control-config-file=$ADMISSION_CONFIG_FILE" >> /etc/rancher/rke2/config.yaml

    # Create combined admission config with PodSecurity + EventRateLimit
    cat > "$ADMISSION_CONFIG_FILE" <<'ADMISSIONEOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1
    kind: PodSecurityConfiguration
    defaults:
      enforce: "restricted"
      enforce-version: "latest"
      audit: "restricted"
      audit-version: "latest"
      warn: "restricted"
      warn-version: "latest"
    exemptions:
      usernames: []
      runtimeClasses: []
      namespaces: [kube-system, cis-operator-system, tigera-operator, cilium-spire]
- name: EventRateLimit
  configuration:
    apiVersion: eventratelimit.admission.k8s.io/v1alpha1
    kind: Configuration
    limits:
    - type: Namespace
      qps: 50
      burst: 100
      cacheSize: 2000
    - type: User
      qps: 10
      burst: 50
ADMISSIONEOF
    echo "Created admission config with EventRateLimit: $ADMISSION_CONFIG_FILE"
  fi

  # Audit logging (K.1.2.11-14)
  # CIS profile auto-configures kube-apiserver flags:
  #   --audit-policy-file=/etc/rancher/rke2/audit-policy.yaml
  #   --audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log
  #   --audit-log-maxage=30, --audit-log-maxbackup=10, --audit-log-maxsize=100
  # We pre-create the audit policy file BEFORE RKE2 starts so it uses our custom
  # policy instead of generating the default (level: None) which logs nothing.
  AUDIT_ENABLED=$(yq_read '.rke2.cis.hardening.audit.enabled' "$ARGOCD_CONFIG_FILE")
  AUDIT_ENABLED=${AUDIT_ENABLED:-true}

  if [ "$AUDIT_ENABLED" = "true" ]; then
    echo "Creating custom audit policy: /etc/rancher/rke2/audit-policy.yaml"
    cat > /etc/rancher/rke2/audit-policy.yaml <<'AUDITEOF'
apiVersion: audit.k8s.io/v1
kind: Policy
# Skip RequestReceived stage (fires before handler, ~50% volume reduction)
omitStages:
  - "RequestReceived"
rules:
  # ============================================================
  # EXCLUSIONS (high-volume, low-value)
  # ============================================================

  # Health/readiness probes and metrics endpoints
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/metrics"

  # Events and endpoints (informational, not security-relevant)
  - level: None
    resources:
      - group: ""
        resources: ["events", "endpoints"]
      - group: "events.k8s.io"
        resources: ["events"]

  # Leader election and node heartbeats (very high volume, no security value)
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # Read-only operations on high-churn resources
  - level: None
    verbs: ["get", "list"]
    resources:
      - group: ""
        resources: ["nodes/status", "pods/status"]

  # ============================================================
  # SENSITIVE RESOURCES (metadata only - never log body)
  # Placed BEFORE system components exclusion so that reads on
  # secrets/configmaps by system accounts are still captured.
  # Placed BEFORE watch exclusion so watches on secrets/configmaps
  # are still captured at Metadata level.
  # ============================================================

  # Secrets: metadata only to prevent credential leakage in audit logs
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  # ConfigMaps: metadata only (may contain sensitive configuration)
  - level: Metadata
    resources:
      - group: ""
        resources: ["configmaps"]

  # Token reviews and access reviews: metadata only
  - level: Metadata
    resources:
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews", "selfsubjectaccessreviews", "selfsubjectrulesreviews"]

  # Certificate signing requests: track certificate issuance
  - level: Metadata
    resources:
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests"]

  # ============================================================
  # SYSTEM COMPONENTS EXCLUSION
  # Placed AFTER sensitive resources so that system account
  # access to secrets/configmaps is still logged at Metadata.
  # ============================================================

  # Internal system components read operations (very high volume)
  # Mutations by system accounts are still logged via subsequent rules
  - level: None
    users:
      - "system:kube-scheduler"
      - "system:kube-proxy"
      - "system:apiserver"
      - "system:kube-controller-manager"
      - "system:serviceaccount:kube-system:generic-garbage-collector"
      - "system:serviceaccount:kube-system:namespace-controller"
      - "system:serviceaccount:kube-system:resourcequota-controller"
      - "system:serviceaccount:kube-system:coredns"
      - "system:serviceaccount:kube-system:endpointslice-controller"
      - "system:serviceaccount:kube-system:endpoint-controller"
    verbs: ["get", "list", "watch"]

  # Watch operations (continuous streams, very high volume)
  - level: None
    verbs: ["watch"]

  # ============================================================
  # SECURITY-CRITICAL MUTATIONS (full request+response)
  # ============================================================

  # Interactive container access: full forensic trail
  # Includes "get" because kubectl exec uses WebSocket upgrade (GET) since K8s 1.30+
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/portforward", "pods/attach"]
    verbs: ["create", "get"]

  # RBAC changes: full audit trail for forensics
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
    verbs: ["create", "delete", "update", "patch"]

  # Namespace and ServiceAccount lifecycle
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["namespaces", "serviceaccounts"]
    verbs: ["create", "delete", "update", "patch"]

  # Admission webhooks: modification can bypass all security policies
  - level: RequestResponse
    resources:
      - group: "admissionregistration.k8s.io"
        resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations"]
    verbs: ["create", "delete", "update", "patch"]

  # ============================================================
  # WORKLOAD MUTATIONS (request body for change tracking)
  # ============================================================

  # Pod and workload operations
  - level: Request
    resources:
      - group: ""
        resources: ["pods"]
      - group: "apps"
        resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - group: "batch"
        resources: ["jobs", "cronjobs"]
    verbs: ["create", "delete", "update", "patch"]

  # Network and storage mutations
  - level: Request
    resources:
      - group: ""
        resources: ["services", "persistentvolumeclaims", "persistentvolumes"]
      - group: "networking.k8s.io"
      - group: "cilium.io"
      - group: "crd.projectcalico.org"
      - group: "gateway.networking.k8s.io"
    verbs: ["create", "delete", "update", "patch"]

  # ============================================================
  # CATCH-ALL: metadata for everything else
  # ============================================================
  - level: Metadata
AUDITEOF
    echo "✓ Custom audit policy created (replaces CIS default level: None)"
  else
    echo "⚠ Audit logging disabled in config - CIS default policy (level: None) will be used"
  fi

  # Add kubelet args for CIS hardening (K.4.2.1, K.4.2.6, K.4.2.8, K.4.2.11, K.4.2.13)
  echo "kubelet-arg:" >> /etc/rancher/rke2/config.yaml
  echo "- anonymous-auth=$ANONYMOUS_AUTH" >> /etc/rancher/rke2/config.yaml
  echo "- make-iptables-util-chains=$MAKE_IPTABLES_UTIL_CHAINS" >> /etc/rancher/rke2/config.yaml
  echo "- event-qps=$EVENT_QPS" >> /etc/rancher/rke2/config.yaml
  echo "- pod-max-pids=$POD_MAX_PIDS" >> /etc/rancher/rke2/config.yaml
  echo "- protect-kernel-defaults=$PROTECT_KERNEL_DEFAULTS" >> /etc/rancher/rke2/config.yaml
fi

# echo "kube-controller-manager-arg: [node-monitor-period=2s, node-monitor-grace-period=16s, pod-eviction-timeout=30s]" >> /etc/rancher/rke2/config.yaml
# echo "node-label: [site=xxx, room=xxx]" >> /etc/rancher/rke2/config.yaml

# Configure CNI-specific settings
# LB_PROVIDER is passed from Vagrantfile (metallb, cilium, loxilb, or klipper)
export LB_PROVIDER="${LB_PROVIDER:-metallb}"
echo "LoadBalancer provider: $LB_PROVIDER"

# GATEWAY_API_PROVIDER is passed from Vagrantfile (cilium, traefik, istio, etc.)
export GATEWAY_API_PROVIDER="${GATEWAY_API_PROVIDER:-traefik}"
echo "Gateway API provider: $GATEWAY_API_PROVIDER"

# Enable ServiceLB (Klipper) if provider is klipper
if [ "$LB_PROVIDER" = "klipper" ]; then
  echo "Enabling ServiceLB (Klipper) in RKE2 config..."
  echo "enable-servicelb: true" >> /etc/rancher/rke2/config.yaml
fi

# Read Service Mesh settings from ArgoCD config (features.serviceMesh)
SERVICE_MESH_ENABLED=$(yq_read '.features.serviceMesh.enabled' "$ARGOCD_CONFIG_FILE")
SERVICE_MESH_ENABLED=${SERVICE_MESH_ENABLED:-false}
SERVICE_MESH_PROVIDER=$(yq_read '.features.serviceMesh.provider' "$ARGOCD_CONFIG_FILE")
SERVICE_MESH_PROVIDER=${SERVICE_MESH_PROVIDER:-none}
export SERVICE_MESH_ENABLED SERVICE_MESH_PROVIDER
echo "Service mesh: $SERVICE_MESH_ENABLED (provider=$SERVICE_MESH_PROVIDER)"

if [ "$CNI_PRIMARY" = "cilium" ]; then
  # Read Cilium encryption settings from ArgoCD config (features.cilium.encryption)
  CILIUM_ENCRYPTION_ENABLED=$(yq_read '.features.cilium.encryption.enabled' "$ARGOCD_CONFIG_FILE")
  CILIUM_ENCRYPTION_ENABLED=${CILIUM_ENCRYPTION_ENABLED:-true}
  CILIUM_ENCRYPTION_TYPE=$(yq_read '.features.cilium.encryption.type' "$ARGOCD_CONFIG_FILE")
  CILIUM_ENCRYPTION_TYPE=${CILIUM_ENCRYPTION_TYPE:-wireguard}
  CILIUM_NODE_ENCRYPTION=$(yq_read '.features.cilium.encryption.nodeEncryption' "$ARGOCD_CONFIG_FILE")
  CILIUM_NODE_ENCRYPTION=${CILIUM_NODE_ENCRYPTION:-true}
  CILIUM_STRICT_MODE=$(yq_read '.features.cilium.encryption.strictMode.enabled' "$ARGOCD_CONFIG_FILE")
  CILIUM_STRICT_MODE=${CILIUM_STRICT_MODE:-true}
  # Read Cilium mutual authentication settings (features.cilium.mutualAuth)
  CILIUM_MUTUAL_AUTH=$(yq_read '.features.cilium.mutualAuth.enabled' "$ARGOCD_CONFIG_FILE")
  CILIUM_MUTUAL_AUTH=${CILIUM_MUTUAL_AUTH:-true}
  CILIUM_MUTUAL_AUTH_PORT=$(yq_read '.features.cilium.mutualAuth.port' "$ARGOCD_CONFIG_FILE")
  CILIUM_MUTUAL_AUTH_PORT=${CILIUM_MUTUAL_AUTH_PORT:-4250}
  export CILIUM_ENCRYPTION_ENABLED CILIUM_ENCRYPTION_TYPE CILIUM_NODE_ENCRYPTION CILIUM_STRICT_MODE
  export CILIUM_MUTUAL_AUTH CILIUM_MUTUAL_AUTH_PORT
  echo "Cilium encryption: $CILIUM_ENCRYPTION_ENABLED (type=$CILIUM_ENCRYPTION_TYPE, nodeEncryption=$CILIUM_NODE_ENCRYPTION, strictMode=$CILIUM_STRICT_MODE)"
  echo "Cilium mutual auth: $CILIUM_MUTUAL_AUTH (port=$CILIUM_MUTUAL_AUTH_PORT)"

  $SCRIPT_DIR/configure_cilium.sh
elif [ "$CNI_PRIMARY" = "calico" ]; then
  # Read Calico settings from ArgoCD config (features.calico)
  CALICO_DATAPLANE=$(yq_read '.features.calico.dataplane' "$ARGOCD_CONFIG_FILE")
  CALICO_DATAPLANE=${CALICO_DATAPLANE:-bpf}
  CALICO_ENCAPSULATION=$(yq_read '.features.calico.encapsulation' "$ARGOCD_CONFIG_FILE")
  CALICO_ENCAPSULATION=${CALICO_ENCAPSULATION:-VXLAN}
  CALICO_BGP_ENABLED=$(yq_read '.features.calico.bgp.enabled' "$ARGOCD_CONFIG_FILE")
  CALICO_BGP_ENABLED=${CALICO_BGP_ENABLED:-false}
  export CALICO_DATAPLANE CALICO_ENCAPSULATION CALICO_BGP_ENABLED
  echo "Calico dataplane: $CALICO_DATAPLANE (encapsulation=$CALICO_ENCAPSULATION, bgp=$CALICO_BGP_ENABLED)"

  $SCRIPT_DIR/configure_calico.sh
else
  echo "ERROR: Unsupported CNI primary: $CNI_PRIMARY (supported: cilium, calico)"
  exit 1
fi

# CoreDNS k8s.lan forwarding to external-dns (only for providers with static IPs)
# Klipper uses node IPs so static IP forwarding is not supported
if [ "$LB_PROVIDER" != "klipper" ]; then
  # Read external-dns static IP from ArgoCD config
  EXTERNAL_DNS_IP=$(yq_read '.features.loadBalancer.staticIPs.externalDns' "$ARGOCD_CONFIG_FILE")
  if [ -n "$EXTERNAL_DNS_IP" ]; then
    echo "Configuring CoreDNS to forward k8s.lan to external-dns ($EXTERNAL_DNS_IP)..."
    mkdir -p /var/lib/rancher/rke2/server/manifests
    cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-coredns-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-coredns
  namespace: kube-system
spec:
  valuesContent: |-
    servers:
      - zones:
          - zone: .
            use_tcp: true
        port: 53
        plugins:
          - name: errors
          - name: health
            configBlock: |-
              lameduck 10s
          - name: ready
          - name: kubernetes
            parameters: cluster.local in-addr.arpa ip6.arpa
            configBlock: |-
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
              ttl 30
          - name: prometheus
            parameters: 0.0.0.0:9153
          - name: forward
            parameters: . /etc/resolv.conf
          - name: cache
            parameters: 30
          - name: loop
          - name: reload
          - name: loadbalance
      - zones:
          - zone: k8s.lan.
        port: 53
        plugins:
          - name: errors
          - name: log
          - name: cache
            parameters: 30
          - name: forward
            parameters: . $EXTERNAL_DNS_IP
            configBlock: |-
              health_check 5s
              max_fails 3
              expire 10s
EOF
    echo "✓ CoreDNS HelmChartConfig created (k8s.lan -> $EXTERNAL_DNS_IP)"
  else
    echo "⚠ No externalDns static IP found in config, skipping CoreDNS k8s.lan config"
  fi
else
  echo "⚠ Klipper provider detected - CoreDNS k8s.lan forwarding not supported (no static IPs)"
fi

systemctl enable --now rke2-server.service

# CIS File Permissions Fixes (K.1.1.12, K.1.1.20)
# These must run after RKE2 creates the directories
if [ "$CIS_ENABLED" = "true" ]; then
  # Create permission fix script
  cat > /usr/local/bin/rke2-cis-permissions.sh <<'PERMSCRIPT'
#!/bin/bash
# RKE2 CIS Permissions Fix Script
# Fixes K.1.1.12 (etcd ownership) and K.1.1.20 (PKI permissions)

# K.1.1.12 - Fix etcd data directory ownership
ETCD_DIR="/var/lib/rancher/rke2/server/db/etcd"
if [ -d "$ETCD_DIR" ]; then
  chown -R etcd:etcd "$ETCD_DIR"
  echo "Fixed etcd ownership: $ETCD_DIR"
fi

# K.1.1.20 - Fix PKI private key permissions (600 instead of 644)
TLS_DIR="/var/lib/rancher/rke2/server/tls"
if [ -d "$TLS_DIR" ]; then
  find "$TLS_DIR" -name "*.key" -exec chmod 600 {} \;
  echo "Fixed PKI key permissions in: $TLS_DIR"
fi

# Also fix etcd PKI keys
ETCD_TLS_DIR="/var/lib/rancher/rke2/server/tls/etcd"
if [ -d "$ETCD_TLS_DIR" ]; then
  find "$ETCD_TLS_DIR" -name "*.key" -exec chmod 600 {} \;
  echo "Fixed etcd PKI key permissions in: $ETCD_TLS_DIR"
fi
PERMSCRIPT
  chmod +x /usr/local/bin/rke2-cis-permissions.sh

  # Create systemd service to apply permissions after each boot
  cat > /etc/systemd/system/rke2-cis-permissions.service <<'SVCEOF'
[Unit]
Description=RKE2 CIS Permissions Fix
After=rke2-server.service
Requires=rke2-server.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rke2-cis-permissions.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

  # Enable and run the service
  systemctl daemon-reload
  systemctl enable rke2-cis-permissions.service

  # Wait for RKE2 to create directories, then apply permissions
  echo "Waiting for RKE2 to initialize before applying CIS permission fixes..."
  for i in {1..30}; do
    if [ -d "/var/lib/rancher/rke2/server/db/etcd" ]; then
      /usr/local/bin/rke2-cis-permissions.sh
      break
    fi
    sleep 2
  done
fi

crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock

# # Brew requirements
# apt-get install -y build-essential procps curl file git
# curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | sudo -u vagrant bash -
# echo 'eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >>~vagrant/.bashrc
# sed -i '1i eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' ~/.bashrc

# # Helm
# # curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install helm'

# # Krew
# # kubectl krew
# # (
# #   krew_tmp_dir="$(mktemp -d)" &&
# #     curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz" &&
# #     tar zxvf krew-linux_amd64.tar.gz &&
# #     KREW=./krew-linux_amd64 &&
# #     "${KREW}" install krew
# #   rm -fr "${krew_tmp_dir}"
# # )
# sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install krew'
# eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)

# export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
# # https://krew.sigs.k8s.io/plugins/
# kubectl krew install ctx           # https://artifacthub.io/packages/krew/krew-index/ctx
# kubectl krew install ns            # https://artifacthub.io/packages/krew/krew-index/ns
# kubectl krew install access-matrix # https://artifacthub.io/packages/krew/krew-index/access-matrix
# kubectl krew install get-all       # https://artifacthub.io/packages/krew/krew-index/get-all
# kubectl krew install deprecations  # https://artifacthub.io/packages/krew/krew-index/deprecations
# kubectl krew install explore       # https://artifacthub.io/packages/krew/krew-index/explore
# kubectl krew install images        # https://artifacthub.io/packages/krew/krew-index/images
# kubectl krew install neat          # https://artifacthub.io/packages/krew/krew-index/neat
# kubectl krew install pod-inspect   # https://artifacthub.io/packages/krew/krew-index/pod-inspect
# kubectl krew install pexec         # https://artifacthub.io/packages/krew/krew-index/pexec
# # echo 'source <(kpexec --completion bash)' >>~/.bashrc

# # kubectl krew install outdated      # https://artifacthub.io/packages/krew/krew-index/outdated
# # kubectl krew install sniff         # https://artifacthub.io/packages/krew/krew-index/sniff
# # kubectl krew install ingress-nginx # https://artifacthub.io/packages/krew/krew-index/ingress-nginx
# # Waiting for the kubernetes API before interacting with it

# # Install which linuxbrew
# sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install kustomize cilium-cli hubble k9s'

while true; do
  lsof -Pni:6443 &>/dev/null && break
  echo "Waiting for the kubernetes API..."
  sleep 1
done

# Disable kube-proxy after Calico BPF is ready (post-bootstrap)
# kube-proxy is needed at bootstrap for Tigera operator to reach API server via ClusterIP.
# Once Calico BPF takes over service routing, kube-proxy becomes redundant and conflicts
# on port 10256 (healthz). We wait for Calico BPF to be ready, then remove kube-proxy.
if [ "$CNI_PRIMARY" = "calico" ] && [ "$CALICO_DATAPLANE" = "bpf" ]; then
  echo "Waiting for Calico BPF to be ready before disabling kube-proxy..."
  for i in $(seq 1 120); do
    if kubectl get pods -n calico-system -l k8s-app=calico-node -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
      # Verify calico-node container is actually ready (not just Running)
      if kubectl wait --for=condition=Ready pod -l k8s-app=calico-node -n calico-system --timeout=5s 2>/dev/null; then
        echo "Calico BPF is ready, disabling kube-proxy..."
        # Add disable-kube-proxy to RKE2 config (prevents kube-proxy on restart)
        echo "disable-kube-proxy: true # Calico BPF replaced kube-proxy (added post-bootstrap)" >> /etc/rancher/rke2/config.yaml
        # Remove kube-proxy static pod manifest (kubelet stops it automatically)
        rm -f /var/lib/rancher/rke2/agent/pod-manifests/kube-proxy.yaml
        echo "✓ kube-proxy disabled (Calico BPF handles service routing)"
        break
      fi
    fi
    [ "$i" -eq 120 ] && echo "⚠ Timeout waiting for Calico BPF - kube-proxy kept active"
    sleep 2
  done
fi

# Configure default PriorityClass to avoid preemption
cat <<EOF | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: nonpreempting
value: 0
preemptionPolicy: Never
globalDefault: true
description: "This priority class will not cause other pods to be preempted."
EOF
