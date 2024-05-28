#!/usr/bin/env bash
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
- rke2-canal # disable it with cilium
# - rke2-metrics-server
# - rke2-ingress-nginx
# - rke2-coredns
# disable: [rke2-ingress-nginx, rke2-coredns]
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
etcd-expose-metrics: true
kube-controller-manager-arg:
# - address=0.0.0.0
- bind-address=0.0.0.0
# kube-proxy-arg:
# - address=0.0.0.0
# - metrics-bind-address=0.0.0.0
# kube-apiserver-arg:
#   - feature-gates=TopologyAwareHints=true,JobTrackingWithFinalizers=true
kube-scheduler-arg:
- bind-address=0.0.0.0" \
>> /etc/rancher/rke2/config.yaml

# Examples tuning Cilium
# Cilium’s eBPF kube-proxy replacement currently cannot be used with Transparent Encryption
# Cf https://github.com/rancher/rke2-charts/tree/main/charts/rke2-cilium/rke2-cilium/1.14.100
# Cf https://artifacthub.io/packages/helm/cilium/cilium
mkdir -p /var/lib/rancher/rke2/server/manifests
cat << EOF > /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    # image:
    #   tag: v1.14.3 # Fix L2 Announcements Lease issue
    kubeProxyReplacement: true # https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/
    k8sServiceHost: 127.0.0.1 # IP dataplane (master) / comment this line if you set kubeProxyReplacement=false
    k8sServicePort: 6443 # Comment this line if you set kubeProxyReplacement=false
    routingMode: native # https://docs.cilium.io/en/latest/network/concepts/routing/#native-routing
    ipv4NativeRoutingCIDR: 10.0.0.0/8 # https://docs.cilium.io/en/latest/network/clustermesh/clustermesh/#additional-requirements-for-native-routed-datapath-modes
    # routingMode: tunnel # https://docs.cilium.io/en/latest/network/concepts/routing/
    # autoDirectNodeRoutes: true
    # tunnelProtocol: ""
    # tunnelProtocol: geneve # https://docs.cilium.io/en/latest/security/policy/caveats/#security-identity-for-n-s-service-traffic
    devices:
    - ^eth[0-9]+
    # - eth0
    externalIPs:
      enabled: true
    nodePort:
      enabled: false
    # socketLB:
    #   enabled: true
    #   hostNamespaceOnly: true # (For Istio by example) https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#socket-loadbalancer-bypass-in-pod-namespace
    # sessionAffinity: ClientIP # https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/#session-affinity
    # ingressController:
    #   enabled: true
    #   default: true
    #   loadbalancerMode: shared # https://docs.cilium.io/en/stable/network/servicemesh/ingress/ (Cf Annotations: ingress.cilium.io/loadbalancer-mode: shared|dedicated)
    # extraConfig:
    #   enable-envoy-config: true # https://docs.cilium.io/en/stable/network/servicemesh/l7-traffic-management/ (envoy traffic management feature without Ingress support (ingressController.enabled=false))
    l7Proxy: true
    loadBalancer:
      mode: dsr # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#direct-server-return-dsr
      dsrDispatch: geneve # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#direct-server-return-dsr-with-geneve
      algorithm: maglev # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#maglev-consistent-hashing
      serviceTopology: true # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#topology-aware-hints
      # acceleration: native # https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#loadbalancer-nodeport-xdp-acceleration
      l7:
        algorithm: least_request # round_robin, least_request, random (cf https://docs.cilium.io/en/stable/network/servicemesh/envoy-load-balancing/#supported-annotations)
        backend: envoy # https://docs.cilium.io/en/stable/network/servicemesh/l7-traffic-management/
    # maglev:
    #   tableSize: 65521
    #   hashSeed: $(head -c12 /dev/urandom | base64 -w0)
    # gatewayAPI: # https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/
    #   enabled: true # require kubeProxyReplacement=true
    enableCiliumEndpointSlice: true # https://docs.cilium.io/en/latest/network/kubernetes/ciliumendpointslice_beta/#deploy-cilium-with-ces
    bpf:
      # preallocateMaps: true # Increase memory usage but can reduce latency
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
          enabled: true
          labels:
            release: prometheus-stack
    encryption:
      enabled: false
      type: wireguard # https://docs.cilium.io/en/latest/security/network/encryption-wireguard
      nodeEncryption: true # https://docs.cilium.io/en/latest/security/network/encryption-wireguard/#node-to-node-encryption-beta
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
    # bgpControlPlane: # replace bgp
    #   enabled: true
    l2announcements: # https://docs.cilium.io/en/stable/network/l2-announcements/
      enabled: true
      # leaseDuration: 3s
      # leaseRenewDeadline: 1s
      # leaseRetryPeriod: 500ms
      # leaseDuration: 300s
      # leaseRenewDeadline: 60s
      # leaseRetryPeriod: 10s
    # k8sClientRateLimit: # https://docs.cilium.io/en/latest/network/l2-announcements/#sizing-client-rate-limit
    #   qps: 10
    #   burst: 25
    # sctp:
    #   # -- Enable SCTP support. NOTE: Currently, SCTP support does not support rewriting ports or multihoming.
    #   enabled: true
    ipv4:
      enabled: true
    enableIPv4BIGTCP: true
    ipv6:
      enabled: false
    enableIPv6BIGTCP: false
    hubble:
      enabled: true
      metrics:
        enableOpenMetrics: true
        serviceMonitor:
          enabled: true
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
              enabled: true
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
        enabled: true
        labels:
          release: prometheus-stack
    dashboard:
      enabled: true
      # namespace: ~
      label: grafana_dashboard
      labelValue: "1"
      annotations:
        grafana_folder: /tmp/dashboards/Cilium
    envoy:
      enabled: true # Install Envoy as DaemonSet instead of Pod (https://docs.cilium.io/en/stable/security/network/proxy/envoy/)
      prometheus:
        enabled: true
        serviceMonitor:
          enabled: true
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
    #         enabled: true
    #         labels:
    #           release: prometheus-stack
EOF

# etcd-snapshot-name: xxx
# etcd-snapshot-schedule-cron: */22****
# etcd-snapshot-retention: 7
# etcd-s3: true
# etcd-s3-bucket: minio
# etcd-s3-region: us-north-9
# etcd-s3-endpoint: minio.gigix
# etcd-s3-access-key: **************************
# etcd-s3-secret-key: **************************


# echo "kube-controller-manager-arg: [node-monitor-period=2s, node-monitor-grace-period=16s, pod-eviction-timeout=30s]" >> /etc/rancher/rke2/config.yaml
# echo "node-label: [site=xxx, room=xxx]" >> /etc/rancher/rke2/config.yaml
systemctl enable --now rke2-server.service
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubectl krew
(
  krew_tmp_dir="$(mktemp -d)" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-linux_amd64.tar.gz" &&
  tar zxvf krew-linux_amd64.tar.gz &&
  KREW=./krew-linux_amd64 &&
  "${KREW}" install krew
  rm -fr "${krew_tmp_dir}"
)

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

# Install kustomize
(cd /usr/local/bin && curl -s https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh | bash)

# Install Cilium
(mkdir cilium && cd cilium && wget https://github.com/cilium/cilium-cli/releases/download/$(curl -s https://api.github.com/repos/cilium/cilium-cli/releases/latest | jq -r '.tag_name')/cilium-linux-amd64.tar.gz && tar xzf cilium-linux-amd64.tar.gz && mv cilium /usr/local/bin/ && cd .. && rm -fr cilium)

# Install Hubble
(mkdir hubble && cd hubble && wget https://github.com/cilium/hubble/releases/download/$(curl -s https://api.github.com/repos/cilium/hubble/releases/latest | jq -r '.tag_name')/hubble-linux-amd64.tar.gz && tar xzf hubble-linux-amd64.tar.gz && mv hubble /usr/local/bin/ && cd .. && rm -fr hubble)

# Install k9s (Cf https://k9scli.io/)
(mkdir k9s && cd k9s && wget https://github.com/derailed/k9s/releases/download/$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')/k9s_Linux_amd64.tar.gz && tar xzf k9s_Linux_amd64.tar.gz && mv k9s /usr/local/bin/ && cd .. && rm -fr k9s)

while true
  do
  lsof -Pni:6443 &>/dev/null && break
  echo "Waiting for the kubernetes API..."
  sleep 1
done

# Change ClusterIP to LoadBalancer
kubectl patch svc kubernetes -n default -p '{"spec": {"type": "LoadBalancer"}, "metadata": {"annotations": {"external-dns.alpha.kubernetes.io/hostname": "k8s-api.gigix", "io.cilium/lb-ipam-ips": "192.168.122.200"}}}'

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