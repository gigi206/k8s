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

curl -sfL https://get.rke2.io | sh -
mkdir -p /etc/rancher/rke2

# Read CIS configuration from ArgoCD config (single source of truth)
ARGOCD_CONFIG_FILE="$PROJECT_ROOT/deploy/argocd/config/config.yaml"
CIS_ENABLED=$(grep -A5 "^rke2:" "$ARGOCD_CONFIG_FILE" | grep "enabled:" | awk '{print $2}' | tr -d ' ')
CIS_PROFILE=$(grep -A5 "^rke2:" "$ARGOCD_CONFIG_FILE" | grep "profile:" | awk '{print $2}' | tr -d '"' | tr -d ' ')

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
  DENY_SERVICE_EXTERNAL_IPS=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "denyServiceExternalIPs:" | awk '{print $2}' | tr -d ' ')
  EVENT_RATE_LIMIT=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "eventRateLimit:" | awk '{print $2}' | tr -d ' ')
  ALWAYS_PULL_IMAGES=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "alwaysPullImages:" | awk '{print $2}' | tr -d ' ')
  REQUEST_TIMEOUT=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "requestTimeout:" | awk '{print $2}' | tr -d '"' | tr -d ' ')
  SERVICE_ACCOUNT_LOOKUP=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "serviceAccountLookup:" | awk '{print $2}' | tr -d ' ')
  EVENT_QPS=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "eventQps:" | awk '{print $2}' | tr -d ' ')
  POD_MAX_PIDS=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "podMaxPids:" | awk '{print $2}' | tr -d ' ')
  ANONYMOUS_AUTH=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "anonymousAuth:" | awk '{print $2}' | tr -d ' ')
  MAKE_IPTABLES_UTIL_CHAINS=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "makeIptablesUtilChains:" | awk '{print $2}' | tr -d ' ')
  PROTECT_KERNEL_DEFAULTS=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "protectKernelDefaults:" | awk '{print $2}' | tr -d ' ')
  FIX_ETCD_OWNERSHIP=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "fixEtcdOwnership:" | awk '{print $2}' | tr -d ' ')
  FIX_PKI_PERMISSIONS=$(grep -A20 "hardening:" "$ARGOCD_CONFIG_FILE" | grep "fixPkiPermissions:" | awk '{print $2}' | tr -d ' ')

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

# Read CNI configuration from ArgoCD config (using grep/awk for portability)
# CNI primary (under cni: section)
CNI_PRIMARY=$(grep -A2 "^cni:" "$ARGOCD_CONFIG_FILE" | grep "primary:" | awk -F'"' '{print $2}')
CNI_PRIMARY=${CNI_PRIMARY:-cilium}
# Multus enabled (under cni.multus: section)
CNI_MULTUS_ENABLED=$(grep -A10 "^cni:" "$ARGOCD_CONFIG_FILE" | grep -A5 "multus:" | grep "enabled:" | head -1 | awk '{print $2}')
CNI_MULTUS_ENABLED=${CNI_MULTUS_ENABLED:-false}
# Whereabouts IPAM (under cni.multus: section)
CNI_WHEREABOUTS_ENABLED=$(grep -A10 "^cni:" "$ARGOCD_CONFIG_FILE" | grep -A5 "multus:" | grep "whereabouts:" | head -1 | awk '{print $2}')
CNI_WHEREABOUTS_ENABLED=${CNI_WHEREABOUTS_ENABLED:-true}
# LoadBalancer provider (under features.loadBalancer: section)
LB_PROVIDER_CONFIG=$(grep -A5 "loadBalancer:" "$ARGOCD_CONFIG_FILE" | grep "provider:" | head -1 | awk -F'"' '{print $2}')
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
SERVICE_MESH_ENABLED=$(grep -A5 "^  serviceMesh:" "$ARGOCD_CONFIG_FILE" | grep -m1 "enabled:" | awk '{print $2}')
SERVICE_MESH_ENABLED=${SERVICE_MESH_ENABLED:-false}
SERVICE_MESH_PROVIDER=$(grep -A5 "^  serviceMesh:" "$ARGOCD_CONFIG_FILE" | grep "provider:" | head -1 | awk -F'"' '{print $2}')
SERVICE_MESH_PROVIDER=${SERVICE_MESH_PROVIDER:-none}
export SERVICE_MESH_ENABLED SERVICE_MESH_PROVIDER
echo "Service mesh: $SERVICE_MESH_ENABLED (provider=$SERVICE_MESH_PROVIDER)"

if [ "$CNI_PRIMARY" = "cilium" ]; then
  # Read Cilium encryption settings from ArgoCD config (features.cilium.encryption)
  CILIUM_ENCRYPTION_ENABLED=$(grep -A5 "^    encryption:" "$ARGOCD_CONFIG_FILE" | grep -m1 "enabled:" | awk '{print $2}')
  CILIUM_ENCRYPTION_ENABLED=${CILIUM_ENCRYPTION_ENABLED:-true}
  CILIUM_ENCRYPTION_TYPE=$(grep -A5 "^    encryption:" "$ARGOCD_CONFIG_FILE" | grep "type:" | head -1 | awk -F'"' '{print $2}')
  CILIUM_ENCRYPTION_TYPE=${CILIUM_ENCRYPTION_TYPE:-wireguard}
  CILIUM_NODE_ENCRYPTION=$(grep -A5 "^    encryption:" "$ARGOCD_CONFIG_FILE" | grep "nodeEncryption:" | head -1 | awk '{print $2}')
  CILIUM_NODE_ENCRYPTION=${CILIUM_NODE_ENCRYPTION:-true}
  CILIUM_STRICT_MODE=$(grep -A10 "^    encryption:" "$ARGOCD_CONFIG_FILE" | grep -A3 "strictMode:" | grep -m1 "enabled:" | awk '{print $2}')
  CILIUM_STRICT_MODE=${CILIUM_STRICT_MODE:-true}
  # Read Cilium mutual authentication settings (features.cilium.mutualAuth)
  CILIUM_MUTUAL_AUTH=$(grep -A5 "^    mutualAuth:" "$ARGOCD_CONFIG_FILE" | grep -m1 "enabled:" | awk '{print $2}')
  CILIUM_MUTUAL_AUTH=${CILIUM_MUTUAL_AUTH:-true}
  CILIUM_MUTUAL_AUTH_PORT=$(grep -A5 "^    mutualAuth:" "$ARGOCD_CONFIG_FILE" | grep "port:" | head -1 | awk '{print $2}')
  CILIUM_MUTUAL_AUTH_PORT=${CILIUM_MUTUAL_AUTH_PORT:-4250}
  export CILIUM_ENCRYPTION_ENABLED CILIUM_ENCRYPTION_TYPE CILIUM_NODE_ENCRYPTION CILIUM_STRICT_MODE
  export CILIUM_MUTUAL_AUTH CILIUM_MUTUAL_AUTH_PORT
  echo "Cilium encryption: $CILIUM_ENCRYPTION_ENABLED (type=$CILIUM_ENCRYPTION_TYPE, nodeEncryption=$CILIUM_NODE_ENCRYPTION, strictMode=$CILIUM_STRICT_MODE)"
  echo "Cilium mutual auth: $CILIUM_MUTUAL_AUTH (port=$CILIUM_MUTUAL_AUTH_PORT)"

  $SCRIPT_DIR/configure_cilium.sh
elif [ "$CNI_PRIMARY" = "calico" ]; then
  # Read Calico settings from ArgoCD config (features.calico)
  CALICO_DATAPLANE=$(grep -A5 "^  calico:" "$ARGOCD_CONFIG_FILE" | grep "dataplane:" | head -1 | awk -F'"' '{print $2}')
  CALICO_DATAPLANE=${CALICO_DATAPLANE:-bpf}
  CALICO_ENCAPSULATION=$(grep -A5 "^  calico:" "$ARGOCD_CONFIG_FILE" | grep "encapsulation:" | head -1 | awk -F'"' '{print $2}')
  CALICO_ENCAPSULATION=${CALICO_ENCAPSULATION:-VXLAN}
  CALICO_BGP_ENABLED=$(grep -A10 "^  calico:" "$ARGOCD_CONFIG_FILE" | grep -A3 "bgp:" | grep "enabled:" | head -1 | awk '{print $2}')
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
  EXTERNAL_DNS_IP=$(grep -A10 "staticIPs:" "$ARGOCD_CONFIG_FILE" | grep "externalDns:" | awk -F'"' '{print $2}')
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
