#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
export PATH="${PATH}:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
. /vagrant/git/rke2/RKE2_ENV.sh
# export INSTALL_RKE2_VERSION=v1.24.8+rke2r1
# /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
# ln -s /etc/rancher/rke2/rke2.yaml ~/.kube/config

curl -sfL https://get.rke2.io | sh -
mkdir -p /etc/rancher/rke2
# test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/rke2-server" || CONFIG_PATH="/etc/default/rke2-server"
# echo "RKE2_CNI=calico" >> /usr/local/lib/systemd/system/rke2-server.env
# echo "RKE2_CNI=calico" >> "${CONFIG_PATH}"
# echo "cni: [multus, calico]" > /etc/rancher/rke2/config.yaml
echo "disable:
- rke2-ingress-nginx
- rke2-kube-proxy # Disable kube-proxy with Cilium => https://docs.rke2.io/install/network_options/
- rke2-canal # disable it with cilium
# - rke2-metrics-server
# - rke2-ingress-nginx
# - rke2-coredns
# disable: [rke2-ingress-nginx, rke2-coredns]
disable-kube-proxy: true
# kube-controller-manager-arg:
#   - feature-gates=TopologyAwareHints=true
# profile: cis-1.23
# cluster-cidr: 10.220.0.0/16
# service-cidr: 10.221.0.0/16
# node-label:
# - xxx=yyy
# system-default-registry: xxx.fr
disable-kube-proxy: true # Disable kube-proxy with Cilium => https://docs.rke2.io/install/network_options/
cni:
- cilium
write-kubeconfig-mode: "0644"
tls-san:
- k8s-api.gigix
- 192.168.122.200
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
# etcd-s3-endpoint: minio.gigix
# etcd-s3-access-key: **************************
# etcd-s3-secret-key: **************************" \
>>/etc/rancher/rke2/config.yaml

# echo "kube-controller-manager-arg: [node-monitor-period=2s, node-monitor-grace-period=16s, pod-eviction-timeout=30s]" >> /etc/rancher/rke2/config.yaml
# echo "node-label: [site=xxx, room=xxx]" >> /etc/rancher/rke2/config.yaml

# Examples tuning Cilium
# Cilium’s eBPF kube-proxy replacement currently cannot be used with Transparent Encryption
# Cf https://github.com/rancher/rke2-charts/tree/main/charts/rke2-cilium/rke2-cilium/1.14.100
# Cf https://artifacthub.io/packages/helm/cilium/cilium
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
    # devices:
    # - ^eth[0-9]+
    # - eth0
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
    #   hashSeed: $(head -c12 /dev/urandom | base64 -w0)
    gatewayAPI: # https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
      enabled: false # require kubeProxyReplacement=true
    enableCiliumEndpointSlice: true # https://docs.cilium.io/en/latest/network/kubernetes/ciliumendpointslice/#deploy-cilium-with-ces
    ipMasqAgent:
      enabled: false
    bpf:
      preallocateMaps: true # Increase memory usage but can reduce latency
      masquerade: true
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
      # exclusive: false # Set to false with Multus
    l2announcements:
      enabled: true
      interface: eth1
      # leaseDuration: 3s
      # leaseRenewDeadline: 1s
      # leaseRetryPeriod: 500ms
      # leaseDuration: 300s
      # leaseRenewDeadline: 60s
      # leaseRetryPeriod: 10s
    # k8sClientRateLimit: # https://docs.cilium.io/en/latest/network/l2-announcements/#sizing-client-rate-limit
    #   qps: 10
    #   burst: 25
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
        # - dns:query;ignoreAAAA
        - dns
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
        ingress:
          enabled: true
          # className: cilium
          hosts:
            - hubble.gigix
          annotations:
            cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
          tls:
          - secretName: hubble-ui-tls
            hosts:
            - hubble.gigix
    prometheus: # https://docs.cilium.io/en/stable/observability/metrics/
      enabled: true
      # Default port value (9090) needs to be changed since the RHEL cockpit also listens on this port.
      # port: 19090
      # Configure this serviceMonitor section AFTER Rancher Monitoring is enabled!
      serviceMonitor:
        # enabled: true # A activer une fois prometheus-stack installé
        labels:
          release: prometheus-stack
    dashboard:
      enabled: true
      # namespace: ~
      labelValue: "1"
      annotations:
        grafana_folder: /tmp/dashboards/Cilium
    envoy:
      enabled: true # Install Envoy as DaemonSet instead of Pod (https://docs.cilium.io/en/stable/security/network/proxy/envoy/)
      prometheus:
        enabled: true
        serviceMonitor:
          # enabled: true # A activer une fois prometheus-stack installé
          labels:
            release: prometheus-stack
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

# Import etcd client certs required by rke2-coredns-config.yaml
# kubectl -n kube-system create secret generic etcd-client-certs \
#   --from-file=ca.crt=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
#   --from-file=client.crt=/var/lib/rancher/rke2/server/tls/etcd/client.crt \
#   --from-file=client.key=/var/lib/rancher/rke2/server/tls/etcd/client.key

# cat <<EOF >/var/lib/rancher/rke2/server/manifests/rke2-coredns-config.yaml
# apiVersion: helm.cattle.io/v1
# kind: HelmChartConfig
# metadata:
#   name: rke2-coredns
#   namespace: kube-system
# spec:
#   valuesContent: |-
#     rbac:
#       create: true
#       # serviceAccountName: default
#     # isClusterService specifies whether the chart should be deployed as cluster-service or regular k8s app.
#     isClusterService: true
#     extraSecrets:
#     - name: etcd-client-certs
#       mountPath: /etc/coredns/tls/etcd
#     servers:
#     - zones:
#       - zone: .
#       port: 53
#       # -- expose the service on a different port
#       # servicePort: 5353
#       # If serviceType is nodePort you can specify nodePort here
#       # nodePort: 30053
#       # hostPort: 53
#       plugins:
#       - name: errors
#       # Serves a /health endpoint on :8080, required for livenessProbe
#       - name: health
#         configBlock: |-
#           lameduck 5s
#       # Serves a /ready endpoint on :8181, required for readinessProbe
#       - name: ready
#       # Required to query kubernetes API for data
#       - name: kubernetes
#         parameters: cluster.local in-addr.arpa ip6.arpa
#         configBlock: |-
#           pods insecure
#           fallthrough in-addr.arpa ip6.arpa
#           ttl 30
#       # Serves a /metrics endpoint on :9153, required for serviceMonitor
#       - name: prometheus
#         parameters: 0.0.0.0:9153
#       - name: forward
#         parameters: . /etc/resolv.conf
#       - name: cache
#         parameters: 30
#       - name: loop
#       - name: reload
#       - name: loadbalance
#     - zones:
#       - zone: gigix.
#       port: 53
#       plugins:
#       - name: etcd
#         parameters: gigix.
#         configBlock: |-
#               stubzones
#               path /skydns
#               # endpoint http://etcd.kube-system:2379
#               endpoint https://192.168.121.175:2379
#               tls /etc/coredns/tls/etcd/client.crt /etc/coredns/tls/etcd/client.key /etc/coredns/tls/etcd/ca.crt
# EOF

# Start rke2 server
systemctl enable --now rke2-server.service

crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock

# Brew requirements
apt-get install -y build-essential procps curl file git
curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | sudo -u vagrant bash -
echo 'eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >>~vagrant/.bashrc
sed -i '1i eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' ~/.bashrc

# Helm
# curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install helm'

# Krew
# kubectl krew
# (
#   krew_tmp_dir="$(mktemp -d)" &&
#     curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz" &&
#     tar zxvf krew-linux_amd64.tar.gz &&
#     KREW=./krew-linux_amd64 &&
#     "${KREW}" install krew
#   rm -fr "${krew_tmp_dir}"
# )
sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install krew'
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
# https://krew.sigs.k8s.io/plugins/
kubectl krew install ctx           # https://artifacthub.io/packages/krew/krew-index/ctx
kubectl krew install ns            # https://artifacthub.io/packages/krew/krew-index/ns
kubectl krew install access-matrix # https://artifacthub.io/packages/krew/krew-index/access-matrix
kubectl krew install get-all       # https://artifacthub.io/packages/krew/krew-index/get-all
kubectl krew install deprecations  # https://artifacthub.io/packages/krew/krew-index/deprecations
kubectl krew install explore       # https://artifacthub.io/packages/krew/krew-index/explore
kubectl krew install images        # https://artifacthub.io/packages/krew/krew-index/images
kubectl krew install neat          # https://artifacthub.io/packages/krew/krew-index/neat
kubectl krew install pod-inspect   # https://artifacthub.io/packages/krew/krew-index/pod-inspect
kubectl krew install pexec         # https://artifacthub.io/packages/krew/krew-index/pexec
# echo 'source <(kpexec --completion bash)' >>~/.bashrc

# kubectl krew install outdated      # https://artifacthub.io/packages/krew/krew-index/outdated
# kubectl krew install sniff         # https://artifacthub.io/packages/krew/krew-index/sniff
# kubectl krew install ingress-nginx # https://artifacthub.io/packages/krew/krew-index/ingress-nginx
# Waiting for the kubernetes API before interacting with it

# Install which linuxbrew
sudo -u vagrant -i -- bash -c 'export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH" && brew install kustomize cilium-cli hubble k9s'

while true; do
  lsof -Pni:6443 &>/dev/null && break
  echo "Waiting for the kubernetes API..."
  sleep 1
done

# svc : requirements for CoreDNS /skydns
# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: Service
# metadata:
#   name: etcd
#   namespace: kube-system
#   labels:
#     component: etcd
#     tier: control-plane
# spec:
#   ports:
#     - port: 2379
#       targetPort: 2379
#       name: client
#     - port: 2380
#       targetPort: 2380
#       name: peer
#   selector:
#     component: etcd
#     tier: control-plane
# EOF

# Ajout IPs LB 192.168.122.200 à 192.168.122.250 => https://docs.cilium.io/en/stable/network/lb-ipam/
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: apiserver
spec:
  blocks:
  - cidr: 192.168.122.200/32
  serviceSelector:
    matchLabels:
      component: apiserver
      provider: kubernetes
      "io.kubernetes.service.namespace": default
      "io.kubernetes.service.name": kubernetes
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  blocks:
    #- cidr: 10.0.10.0/24
    - start: 192.168.122.201
      stop: 192.168.122.250
  serviceSelector:
    matchExpressions:
      - {key: component, operator: NotIn, values: [apiserver]}
      - {key: provider, operator: NotIn, values: [kubernetes]}
# ---
# apiVersion: cilium.io/v2alpha1
# kind: CiliumL2AnnouncementPolicy
# metadata:
#   name: default
# spec:
#   #serviceSelector:
#   #  matchLabels:
#   #    L2Announcement: true
#   #    expose: true
#   #nodeSelector:
#   #  matchExpressions:
#   #  - key: node-role.kubernetes.io/control-plane
#   #    operator: DoesNotExist
#   #    #operator: Exists
#   interfaces:
#     #- ^eth[0-9]+
#     - ^eth1$
#   externalIPs: true
#   loadBalancerIPs: true
EOF

# Change ClusterIP to LoadBalancer with external-dns.alpha.kubernetes.io/hostname annotation to k8s-api.gigix
kubectl patch svc kubernetes -n default -p '{"spec": {"type": "LoadBalancer"}, "metadata": {"annotations": {"external-dns.alpha.kubernetes.io/hostname": "k8s-api.gigix"}}}'

# Change ClusterIP to LoadBalancer to have DNS available from outside
# kubectl patch svc rke2-coredns-rke2-coredns -n kube-system -p '{"spec": {"type": "LoadBalancer"}}'

# FIXME: Replicas must be set to 1 in the Cilium helm chart
# kubectl scale deployment cilium-operator -n kube-system --replicas=1
# kubectl wait --for=condition=Ready -n kube-system pod -l app.kubernetes.io/name=cilium-operator --timeout=60s && (
#   # Change k8sServiceHost to 192.168.122.200
#   sed -i "s/\(^\s*\)k8sServiceHost:.*/\1k8sServiceHost: $(kubectl get svc kubernetes -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/" /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml

#   # Change k8sServicePort to 443
#   sed -i 's/\(^\s*\)k8sServicePort:.*/\1k8sServicePort: 443/' /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
# )

# Announce L2
# cat <<EOF | kubectl apply -f -
# apiVersion: "cilium.io/v2alpha1"
# kind: CiliumL2AnnouncementPolicy
# metadata:
#   name: policy1
# spec:
#   #serviceSelector:
#   #  matchLabels:
#   #    L2Announcement: true
#   #    expose: true
#   #nodeSelector:
#   #  matchExpressions:
#   #  - key: node-role.kubernetes.io/control-plane
#   #    operator: DoesNotExist
#   #    #operator: Exists
#   interfaces:
#     #- ^eth[0-9]+
#     - ^eth1$
#   externalIPs: true
#   loadBalancerIPs: true
# EOF

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
