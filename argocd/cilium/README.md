# Cilium
## Tuning Guide
https://docs.cilium.io/en/stable/operations/performance/tuning/#tuning-guide

## Benchmark
* https://docs.cilium.io/en/stable/operations/performance/benchmark/

## Kernel version by feature
* https://docs.cilium.io/en/stable/operations/system_requirements/#required-kernel-versions-for-advanced-features

## Feature status
* https://docs.cilium.io/en/stable/community/roadmap/#major-feature-status

## Rebasing a ConfigMap
* https://docs.cilium.io/en/stable/operations/upgrade/#rebasing-a-configmap

## Limitations
* https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/#limitations

## Troubleshooting
* https://docs.cilium.io/en/latest/network/kubernetes/troubleshooting/
* https://docs.cilium.io/en/stable/operations/troubleshooting/
* https://docs.cilium.io/en/stable/contributing/development/debugging/

## Istio integration
* https://docs.cilium.io/en/stable/network/servicemesh/istio/

## Envoy support
* https://docs.cilium.io/en/stable/network/servicemesh/l7-traffic-management/#supported-envoy-api-versions

# Firewall rules
* https://docs.cilium.io/en/stable/operations/system_requirements/#firewall-rules

# Privileges
* https://docs.cilium.io/en/stable/operations/system_requirements/#privileges

# Options
* Removed options: https://docs.cilium.io/en/stable/operations/upgrade/#removed-options
* New options: https://docs.cilium.io/en/stable/operations/upgrade/#new-options
* Deprecated options: https://docs.cilium.io/en/stable/operations/upgrade/#deprecated-options

## Installation
### Kind example
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  ipFamily: dual
  disableDefaultCNI: true
```

```shell
kind create cluster --config "/etc/kind/nocni_2workers_dual.yaml"
```

### K3D example
Cf https://allanjohn909.medium.com/harnessing-the-power-of-cilium-a-guide-to-bgp-integration-with-gateway-api-on-ipv4-7b0d058a1c0d

* Enable Ipv4 Forwarding:
```shell
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/01-sysctl.conf > /dev/null
sudo sysctl -p
```

* Create the Docker `cilium` network:
```shell
docker network create \
      --driver bridge \
      --subnet "172.50.0.0/16" \
      --gateway "172.50.0.1" \
      --ip-range "172.50.0.0/16" \
      "cilium"
```

* Create `k3d-entrypoint-cilium.sh` (K3d calls all `k3d-entrypoint-*.sh` scripts at startup):
```shell
set -e

echo "Mount bpf"
mount bpffs -t bpf /sys/fs/bpf
mount --make-shared /sys/fs/bpf

echo "Mount cgroups"
mkdir -p /run/cilium/cgroupv2
mount -t cgroup2 none /run/cilium/cgroupv2
mount --make-shared /run/cilium/cgroupv2/
```

* `k3d-config.yaml`:
```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: cilium-cluster
servers: 1
agents: 2
# image: docker.io/rancher/k3s:v1.25.7-k3s1
kubeAPI:
  hostIP: 127.172.50.1
  hostPort: "6443"
network: cilium
token: Ciliumk3d1
volumes:
  - volume: /root/k3d-entrypoint-cilium.sh:/bin/k3d-entrypoint-cilium.sh
    nodeFilters:
    - all
options:
  k3d:
    wait: true
    timeout: "6m0s"
    disableLoadbalancer: true
    disableImageVolume: false
    disableRollback: false
  k3s: # options passed on to K3s itself
    # nodeLabels:
    #   - label: bgp_enabled=true
    #     nodeFilters:
    #       - server:*
    #       - agent:*
    extraArgs:
      - arg: --tls-san=127.0.0.1
        nodeFilters:
          - server:*
      - arg: --disable=servicelb
        nodeFilters:
        - server:*
      - arg: --disable=traefik
        nodeFilters:
        - server:*
      - arg: --disable-network-policy
        nodeFilters:
          - server:*
      - arg: --flannel-backend=none
        nodeFilters:
          - server:*
      - arg: --disable=kube-proxy
        nodeFilters:
          - server:*
      - arg: --cluster-cidr=10.21.0.0/16
        nodeFilters:
          - server:*
      - arg: --service-cidr=10.201.0.0/16
        nodeFilters:
          - server:*
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: true
```

* Create the  cluster:
```shell
k3d cluster create -c k3d-config.yaml
```

### Cilium helm
* Helm reference: https://docs.cilium.io/en/latest/helm-reference
* ConfigMap options: https://docs.cilium.io/en/stable/network/kubernetes/configuration/

```shell
helm repo add cilium https://helm.cilium.io/
helm upgrade --install cilium cilium/cilium --version 1.13.0 \
    --namespace kube-system \
    --set hubble.enabled=true \
    --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}" \
    --set hubble.relay.enabled=true
cilium status --wait
```

### Restart unmanaged pod
* https://docs.cilium.io/en/stable/installation/k8s-install-helm/#restart-unmanaged-pods

```shell
kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTNETWORK:.spec.hostNetwork --no-headers=true | grep '<none>' | awk '{print "-n "$1" "$2}' | xargs -L 1 -r kubectl delete pod
```

### Tetragon helm
`tetragon.yaml`:
```shell
tetragon:
  btf: /sys/kernel/btf/vmlinux
  enableCiliumAPI: false
  exportAllowList: ""
  exportDenyList: ""
  exportFilename: "tetragon.log"
  enableProcessCred: true
  enableProcessNs: true
tetragonOperator:
  enabled: true
```

```shell
helm repo add cilium https://helm.cilium.io
helm repo update
helm install tetragon cilium/tetragon -n kube-system -f tetragon.yaml --version 0.10.0
```

#### Cilium helm values
* [ArtifactHUB](https://artifacthub.io/packages/helm/cilium/cilium?modal=values)
* [RKE2](https://github.com/rancher/rke2-charts/blob/main/charts/rke2-cilium/rke2-cilium/1.14.100/values.yaml)

## Tuto
* https://github.com/nvibert/cilium-weekly
* https://blog.wescale.fr/author/st%C3%A9phane-tr%C3%A9bel

## Labs
* https://isovalent.com/resource-library/labs/

You can install a more recent kernel on the lab, for example a 6.4.0 kernel:
```shell
wget https://raw.githubusercontent.com/pimlie/ubuntu-mainline-kernel.sh/master/ubuntu-mainline-kernel.sh
chmod +x ubuntu-mainline-kernel.sh
mv ubuntu-mainline-kernel.sh /usr/local/bin/
ubuntu-mainline-kernel.sh -c
ubuntu-mainline-kernel.sh -i v6.4.0
reboot
```

### NetPerf
```shell
kubectl apply -f https://raw.githubusercontent.com/NikAleksandrov/cilium/42b93676d85783aa167105a91e44078ce6731297/test/bigtcp/netperf.yaml
NETPERF_SERVER=`kubectl get pod netperf-server -o jsonpath='{.status.podIPs}' | jq -r -c '.[].ip | select(contains(":") == false)'`
echo $NETPERF_SERVER
kubectl exec netperf-client -- netperf  -t TCP_RR -H ${NETPERF_SERVER} -- -r80000:80000 -O MIN_LATENCY,P90_LATENCY,P99_LATENCY,THROUGHPUT
```

### Kubeproxy replacement
* https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
```shell
$ kubectl -n kube-system exec ds/cilium -- cilium status --verbose | grep KubeProxyReplacement
KubeProxyReplacement:   True        [eth0 (Direct Routing), eth1]
```

```shell
API_SERVER_IP=<your_api_server_ip>
# Kubeadm default is 6443
API_SERVER_PORT=<your_api_server_port>
helm install cilium cilium/cilium --version 1.14.2 \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=${API_SERVER_IP} \
    --set k8sServicePort=${API_SERVER_PORT}
```

### Host Firewall
* https://docs.cilium.io/en/v1.14/security/host-firewall/
```shell
cilium  install \
  --helm-set hostFirewall.enabled=true \
  --helm-set securityContext.privileged=true \
  --helm-set kubeProxyReplacement=strict \
  --helm-set bpf.monitorAggregation=none
  # --set devices='{ethX,ethY}'
```

```shell
$ cilium config view | grep host-firewall
enable-host-firewall                           true
```

### L2 Advertisement
* https://docs.cilium.io/en/v1.14/network/l2-announcements/#l2-announcements
```shell
cilium install --version v1.14.1 \
  --helm-set kubeProxyReplacement="strict" \
  --helm-set k8sServiceHost="clab-garp-demo-control-plane" \
  --helm-set k8sServicePort=6443 \
  --helm-set l2announcements.enabled=true \
  --helm-set l2announcements.leaseDuration="3s" \
  --helm-set l2announcements.leaseRenewDeadline="1s" \
  --helm-set l2announcements.leaseRetryPeriod="500ms" \
  --helm-set devices="{eth0,net0}" \
  --helm-set externalIPs.enabled=true
```

```shell
$ cilium config view | grep l2
enable-l2-announcements                           true
enable-l2-neigh-discovery                         true
l2-announcements-lease-duration                   3s
l2-announcements-renew-deadline                   1s
l2-announcements-retry-period                     500ms
```

Create a CiliumLoadBalancerIPPool (https://docs.cilium.io/en/stable/network/lb-ipam/):
```yaml
# No selector, match all
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  cidrs:
  - cidr: 192.168.122.0/24
#   serviceSelector:
#     matchExpressions:
#       - {key: color, operator: In, values: [yellow, red, blue]}
```

L2 advertisement (https://docs.cilium.io/en/latest/network/l2-announcements/#policies):
```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: policy1
spec:
  externalIPs: true
  loadBalancerIPs: true
  interfaces:
  - net0
  # serviceSelector:
  #   matchLabels:
  #     color: blue
  # nodeSelector:
  #   matchExpressions:
  #     - key: node-role.kubernetes.io/control-plane
  #       operator: DoesNotExist
```

```shell
$ echo $(kubectl -n kube-system get leases cilium-l2announce-default-deathstar-2 -o jsonpath='{.spec.holderIdentity}')
clab-garp-demo-worker2
```

### BGP
* https://docs.cilium.io/en/latest/network/bgp-toc/
* https://docs.cilium.io/en/stable/network/bgp-control-plane/
```shell
cilium install --version=1.13.0-rc4 \
    --helm-set ipam.mode=kubernetes \
    --helm-set tunnel=disabled \
    --helm-set ipv4NativeRoutingCIDR="10.0.0.0/8" \
    --helm-set bgpControlPlane.enabled=true \
    --helm-set k8s.requireIPv4PodCIDR=true
```

```shell
$ cilium config view | grep enable-bgp
enable-bgp-control-plane                   true
```

#### BGP Advertisement
Create a CiliumLoadBalancerIPPool (https://docs.cilium.io/en/stable/network/lb-ipam/):
```yaml
# No selector, match all
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  cidrs:
  - cidr: 192.168.122.0/24
#   serviceSelector:
#     matchExpressions:
#       - {key: color, operator: In, values: [yellow, red, blue]}
```

* https://docs.cilium.io/en/latest/network/bgp-control-plane/#ciliumbgppeeringpolicy-crd
```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumBGPPeeringPolicy
metadata:
  name: tor
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: clab-bgp-cplane-devel-control-plane
  virtualRouters:
  - localASN: 65001
    exportPodCIDR: true
    # serviceSelector:
    #   matchLabels:
    #     color: yellow
    #   matchExpressions:
    #     - {key: io.kubernetes.service.namespace, operator: In, values: ["tenant-c"]}
    neighbors:
    - peerAddress: "172.0.0.1/32"
      peerASN: 65000
```

### L7 Load-balancing
* https://docs.cilium.io/en/latest/network/servicemesh/l7-traffic-management/
```shell
cilium install --version=1.13.0-rc4 \
--set kubeProxyReplacement=strict \
--set loadBalancer.l7.backend=envoy \
-set-string extraConfig.enable-envoy-config=true
```

```shell
cilium config view | grep -w "kube-proxy"
kube-proxy-replacement                         strict
kube-proxy-replacement-healthz-bind-address
```

```shell
cilium config view | grep envoy
enable-envoy-config                            true
loadbalancer-l7                                envoy
```

### Gateway API
* https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/gateway-api/
```shell
cilium install --version=1.13.0-rc4 \
--set kubeProxyReplacement=strict \
--set gatewayAPI.enabled=true
```

```shell
$ cilium config view | grep -w "enable-gateway-api "
enable-gateway-api                                true
```

### Egress gateway
* https://docs.cilium.io/en/stable/network/egress-gateway/
**NOTE:** The L7 proxy is incompatible with Egress Gateway
```shell
cilium install \
    --helm-set egressGateway.enabled=true \
    --helm-set bpf.masquerade=true \
    --helm-set kubeProxyReplacement=strict \
    --helm-set l7Proxy=false \
    --helm-set devices=eth+
```

### IPV6 support
```shell
cilium install --helm-set ipv6.enabled=true
```

```shell
$ cilium config view | grep ipv6
enable-ipv6                                true
enable-ipv6-masquerade                     true
```

```shell
$ kubectl describe nodes | grep PodCIDRs
kubectl get node -o jsonpath="{range .items[*]}{.metadata.name} {.spec.podCIDR}{'\n'}{end}" | column -t
kind-control-plane  10.244.0.0/24,fd00:10:244::/64
kind-worker         10.244.1.0/24,fd00:10:244:1::/64
kind-worker2        10.244.2.0/24,fd00:10:244:2::/64
kind-worker3        10.244.3.0/24,fd00:10:244:3::/64
```

```shell
$ kubectl describe pod pod-worker | grep -A 2 IPs
IPs:
  IP:  10.244.3.236
  IP:  fd00:10:244:3::1e02
```

```shell
$ kubectl describe svc echoserver | egrep ^IP
IP Family Policy:  PreferDualStack
IP Families:       IPv6,IPv4
IP:                fd00:10:96::ddc1
IPs:               fd00:10:96::ddc1,10.96.24.229
```

```shell
$ kubectl exec -i -t pod-worker -- nslookup -q=AAAA echoserver.default
Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   echoserver.default.svc.cluster.local
Address: fd00:10:96::ddc1
```

# Bandwidth Manager
* https://docs.cilium.io/en/stable/network/kubernetes/bandwidth-manager/
```shell
helm install cilium cilium/cilium --version 1.14.2 \
  --namespace kube-system \
  --set bandwidthManager.enabled=true
  # --set bandwidthManager.bbr=true
```

```shell
$ kubectl -n kube-system exec ds/cilium -- cilium status | grep BandwidthManager
BandwidthManager:       EDT with BPF [BBR] [eth0]
```

# enableCiliumEndpointSlice (ces)
ciliumendpointslices is a **beta** feature:
* https://docs.cilium.io/en/latest/network/kubernetes/ciliumendpointslice/
* https://docs.cilium.io/en/latest/network/kubernetes/ciliumendpointslice_beta/

```shell
helm install cilium ./cilium \
  --set enableCiliumEndpointSlice=true
```

### Mutual Authentication mTLS (Beta)
Require when installing:
```yaml
authentication:
  mutual:
    spire:
      enabled: true
      install:
        enabled: true
```

```shell
cilium config view | grep mesh-auth
mesh-auth-enabled                              true
mesh-auth-expired-gc-interval                  15m0s
mesh-auth-mutual-enabled                       true
mesh-auth-mutual-listener-port                 4250
mesh-auth-queue-size                           1024
mesh-auth-rotated-identities-queue-size        1024
mesh-auth-spiffe-trust-domain                  spiffe.cilium
mesh-auth-spire-admin-socket                   /run/spire/sockets/admin.sock
mesh-auth-spire-agent-socket                   /run/spire/sockets/agent/agent.sock
mesh-auth-spire-server-address                 spire-server.cilium-spire.svc:8081
mesh-auth-spire-server-connection-timeout      30s
```

Mutual TLS require `CiliumNetworkPolicy` with `authentication.mode: required`:
```yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "rule1"
spec:
  description: "Mutual authentication enabled L7 policy"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
  - fromEndpoints:
    - matchLabels:
        org: empire
    authentication:
      mode: "required"
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/v1/request-landing"
```

Check if SPIRE is healthy:
```yaml
$ kubectl exec -n cilium-spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server healthcheck
Server is healthy.
```

Note that there are 2 agents, one per node (and we have two nodes in this cluster).

```shell
$ kubectl exec -n cilium-spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list
Found 2 attested agents:

SPIFFE ID         : spiffe://spiffe.cilium/spire/agent/k8s_psat/default/61e5a9c7-eb39-41e0-b765-c4f124beef6b
Attestation type  : k8s_psat
Expiration time   : 2023-10-14 17:03:30 +0000 UTC
Serial number     : 27408481772698233441302766035247760760

SPIFFE ID         : spiffe://spiffe.cilium/spire/agent/k8s_psat/default/81759df2-346c-4014-b3eb-267faabbcdc4
Attestation type  : k8s_psat
Expiration time   : 2023-10-14 17:03:30 +0000 UTC
Serial number     : 28707821630979914056093212232659136828
```

Verify that the Cilium agent and operator have identities on the SPIRE server:
```shell
$ kubectl exec -n cilium-spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -parentID spiffe://spiffe.cilium/ns/cilium-spire/sa/spire-agent
Found 2 entries
Entry ID         : 1ef0f047-cf57-41dd-8041-0d113dd5b1c9
SPIFFE ID        : spiffe://spiffe.cilium/cilium-agent
Parent ID        : spiffe://spiffe.cilium/ns/cilium-spire/sa/spire-agent
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : k8s:ns:kube-system
Selector         : k8s:sa:cilium

Entry ID         : 95e73049-8aa4-45f7-a067-db28580e0af8
SPIFFE ID        : spiffe://spiffe.cilium/cilium-operator
Parent ID        : spiffe://spiffe.cilium/ns/cilium-spire/sa/spire-agent
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : k8s:ns:kube-system
Selector         : k8s:sa:cilium-operator
```

Show `IDENTITY ID`:
```shell
$ kubectl get cep -l app.kubernetes.io/name=deathstar
NAME                         ENDPOINT ID   IDENTITY ID   INGRESS ENFORCEMENT   EGRESS ENFORCEMENT   VISIBILITY POLICY   ENDPOINT STATE   IPV4         IPV6
deathstar-8464cdd4d9-fdqdn   3002          27682         <status disabled>     <status disabled>    <status disabled>   ready            10.0.1.129
deathstar-8464cdd4d9-mzxdk   2823          27682         <status disabled>     <status disabled>    <status disabled>   ready            10.0.2.56
```

List all the registration entries:
```shell
$ kubectl exec -n cilium-spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -selector cilium:mutual-auth
Found 9 entries
Entry ID         : 07c4feca-a4f4-44f5-8786-e7cd7410af50
SPIFFE ID        : spiffe://spiffe.cilium/identity/16080
Parent ID        : spiffe://spiffe.cilium/cilium-operator
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : cilium:mutual-auth
...
...
```

Show specific ID:
```shell
$ kubectl exec -n cilium-spire spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -spiffeID spiffe://spiffe.cilium/identity/27682
Found 1 entry
Entry ID         : 4660b9ee-d727-447d-9021-8f4bcbad9968
SPIFFE ID        : spiffe://spiffe.cilium/identity/27682
Parent ID        : spiffe://spiffe.cilium/cilium-operator
Revision         : 0
X509-SVID TTL    : default
JWT-SVID TTL     : default
Selector         : cilium:mutual-auth
```

List IDENTITIES:
```shell
$ kubectl get ciliumidentities
NAME    NAMESPACE            AGE
16080   local-path-storage   30m
17321   kube-system          30m
1797    kube-system          30m
19764   local-path-storage   30m
27336   cilium-spire         30m
27682   default              30m
2779    default              30m
37803   default              30m
59566   kube-system          30m
```

## NetworkPolicy editor
* https://editor.networkpolicy.io

## EBPF applications
* https://ebpf.io/applications/

## Cli
### Cilium
#### Download
You can download cilium but it is preferable to use cilium inside the container:
```shell
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz
```

#### IP pools
```shell
$ kubectl get ippools
NAME      DISABLED   CONFLICTING   IPS AVAILABLE   AGE
default   false      False         253             4m40s
```

#### Config
```shell
cilium config view
kubectl -n kube-system exec ds/cilium -- cilium config -a
```

#### Command
```shell
cilium connectivity test
```

```shell
kubectl -n kube-system exec ds/cilium -- cilium status --verbose
```

```shell
kubectl -n kube-system exec ds/cilium -- cilium endpoint list
```

```shell
kubectl -n kube-system exec ds/cilium -- cilium monitor --related-to 2950
```

```shell
kubectl -n kube-system exec -ti ds/cilium -c cilium-agent -- cilium bpf egress list
```

```shell
kubectl -n kube-system exec -ti ds/cilium -c cilium-agent -- cilium bpf tunnel list
```

### Hubble
To use hubble you need to forward port **4245** first (`port-forward`):
```shell
cilium hubble port-forward &
```

Or:
```shell
kubectl port-forward -n kube-system svc/hubble-relay --address 127.0.0.1 4245:80 &
```

#### Download
```shell
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz
tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
rm hubble-linux-amd64.tar.gz
```

#### Observe
Show drop packets from namespace default and pod xxx:
```shell
hubble observe --type drop --from-pod default/xxx
```

Show traffic from/to the Envoy proxy:
```shell
hubble observe --type trace:to-proxy
```

Show specific protocols:
```shell
hubble observe --protocol sctp --follow
hubble observe -n endor --protocol http
hubble observe --namespace tenant-jobs --protocol dns
```

Show new events for namespace `myns`:
```shell
hubble observe -f -n myns
```

Show policy-verdict (require to have a Network Policy defined. If no one is defined no flows should be returned):
```shell
hubble observe --type policy-verdict --from-pod default/xxx
```

For a specific identity:
```shell
CLIENT_ID=$(kubectl get cep client -o jsonpath='{.status.identity.id}')
hubble observe  --pod client --protocol icmp --last 50 --verdict=DROPPED --identity $CLIENT_ID
```

Show trafic to api.github.com
```shell
hubble observe --to-fqdn api.github.com
```

Show the last policy-verdict from `endor/tiefighter` to `endor/deathstar`:
```shell
hubble observe --type policy-verdict --from-pod endor/tiefighter --to-pod endor/deathstar --last 1 -o jsonpb | jq
hubble observe --type policy-verdict --to-port 53 --last 1 -o jsonpb | jq '.flow | select(.egress_allowed_by).egress_allowed_by'
hubble observe --type policy-verdict --last 1 -o jsonpb | jq '.flow | select(.ingress_allowed_by or .egress_allowed_by) | .ingress_allowed_by, .egress_allowed_by'
```

Show drop packets:
```shell
hubble observe --verdict DROPPED
```

Show port 22 (We will filter on identity 1, which is the special identity used by Cilium to refer to Kubernetes nodes):
```shell
hubble observe --to-identity 1 --port 22 -f
```

Show specific HTTP requests:
```shell
hubble observe --http-path "/cilium-add-a-request-header"
hubble observe --namespace tenant-jobs --http-method POST
hubble observe --namespace tenant-jobs --from-label 'app=coreapi' --protocol http --http-path /applicants --http-method PUT
```

##### Oberve with Timescape
Let's expose the Hubble Timescape service, and then we can use the hubble cli to connect to Timescape to pull the same historical data we can view in the UI, via the CLI:
```shell
kubectl -n hubble-timescape port-forward svc/hubble-timescape --address 127.0.0.1 4245:80 &
```

Now to view the Timescape data, we can point this to the exposed service using the --server argument:
```shell
hubble observe --server localhost:4245 --verdict DROPPED -n tenant-jobs
hubble observe --server localhost:4245 --verdict DROPPED -n tenant-jobs --since 30m
```

You can use `--since` and `--until`:*
```
--since string   Filter flows since a specific date. The format is relative (e.g. 3s, 4m, 1h43,, ...) or one of:
                    StampMilli:             Jan _2 15:04:05.000
                    YearMonthDay:           2006-01-02
                    YearMonthDayHour:       2006-01-02T15Z07:00
                    YearMonthDayHourMinute: 2006-01-02T15:04Z07:00
                    RFC3339:                2006-01-02T15:04:05Z07:00
                    RFC3339Milli:           2006-01-02T15:04:05.999Z07:00
                    RFC3339Micro:           2006-01-02T15:04:05.999999Z07:00
                    RFC3339Nano:            2006-01-02T15:04:05.999999999Z07:00
                    RFC1123Z:               Mon, 02 Jan 2006 15:04:05 -0700

--until string   Filter flows until a specific date. The format is relative (e.g. 3s, 4m, 1h43,, ...) or one of:
                    StampMilli:             Jan _2 15:04:05.000
                    YearMonthDay:           2006-01-02
                    YearMonthDayHour:       2006-01-02T15Z07:00
                    YearMonthDayHourMinute: 2006-01-02T15:04Z07:00
                    RFC3339:                2006-01-02T15:04:05Z07:00
                    RFC3339Milli:           2006-01-02T15:04:05.999Z07:00
                    RFC3339Micro:           2006-01-02T15:04:05.999999Z07:00
                    RFC3339Nano:            2006-01-02T15:04:05.999999999Z07:00
                    RFC1123Z:               Mon, 02 Jan 2006 15:04:05 -0700
```

#### Other
```shell
$ hubble list nodes
NAME                 STATUS      AGE     FLOWS/S   CURRENT/MAX-FLOWS
kind-control-plane   Connected   8m14s   20.12     4095/4095 (100.00%)
kind-worker          Connected   8m7s    7.08      3577/4095 ( 87.35%)
kind-worker2         Connected   8m6s    7.84      3892/4095 ( 95.04%)
```

In Isovalent Enterprise for Cilium, Tetragon is part of the Hubble Enterprise component:
```shell
kubectl exec -it -n kube-system daemonsets/hubble-enterprise -c enterprise -- hubble-enterprise getevents -o compact
kubectl exec -it -n kube-system daemonsets/hubble-enterprise -c enterprise -- hubble-enterprise getevents -o compact -n tenant-jobs
kubectl exec -it -n kube-system daemonsets/hubble-enterprise -c enterprise -- hubble-enterprise getevents -o compact --pod mypod
kubectl exec -it -n kube-system daemonsets/hubble-enterprise -c enterprise -- hubble-enterprise getevents -o compact -n tenant-jobs --pod coreapi
```

### Tetragon
```shell
kubectl exec -n kube-system -ti daemonset/tetragon -c tetragon -- tetra getevents -o compact
kubectl exec -n kube-system -ti daemonset/tetragon -c tetragon -- tetra getevents -o compact --pods sith-infiltrator
kubectl exec -n kube-system -ti daemonset/tetragon -c tetragon -- tetra getevents -o compact --process curl,python
```

```shell
kubectl exec -n kube-system -ti daemonset/tetragon -c tetragon -- tail -f /run/cilium/tetragon/tetragon.log | jq -c
kubectl logs -n kube-system daemonset/tetragon -c export-stdout -f | jq -c
```

## Tracing Policy
Examples of tracing Policy used by Tetragon:
```shell
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: trace-all
spec:
  parser:
    interface:
      enable: true
    tcp:
      enable: true
    udp:
      enable: true
    dns:
      enable: true
```

```shell
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: "networking"
spec:
  kprobes:
  - call: "tcp_connect"
    syscall: false
    args:
     - index: 0
       type: "sock"
  - call: "tcp_close"
    syscall: false
    args:
     - index: 0
       type: "sock"
```

```shell
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: "sys-setns"
spec:
  kprobes:
  - call: "__x64_sys_setns"
    syscall: true
    args:
    - index: 0
      type: "int"
    - index: 1
      type: "int"
```

## Network Policy
Cilium provides various entities (most of which map to special identities):
* **host**: the local host (and local containers running in host networking mode)
* **remote**-node: any node in the cluster (or containers running on host networking mode on these nodes) other than host
* **kube**-apiserver: the Kube API server
* **cluster**: any network endpoints inside the local cluster (endpoints, host, remote-host, and init)
* **init**: all endpoints in bootstrap phase (no security identity yet)
* **health**: Cilium's health endpoints (one per node)
* **unmanaged**: endpoints not managed by Cilium
* **world**: all endpoints outside of the cluster
* **all**: anything
All these entities can be used in Cilium Network Policies by using the `toEntities` or `fromEntities` keys.

Examples:
This policy ensures all traffic is allowed by default:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  namespace: default
  name: allow-all
spec:
  endpointSelector:
    {}
  ingress:
    - fromEntities:
      - all
  egress:
    - toEntities:
      - all
```

This policy ensures all traffic is allowed by default in the same namespace:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-all-within-namespace
  namespace: myns
spec:
  description: Allow all within namespace
  egress:
  - toEndpoints:
    - {}
  endpointSelector: {}
  ingress:
  - fromEndpoints:
    - {}
```

This policy allows pods in the namespace to access the Kube DNS service. It also adds a DNS rule to get the DNS traffic proxied through Cilium's DNS proxy, which makes it possible to resolve DNS names in Hubble flows.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-visibility
  namespace: myns
spec:
  egress:
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s:k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: '*'
  - toFQDNs:
    - matchPattern: '*'
  - toEntities:
    - all
  endpointSelector:
    matchLabels: {}
```

This third policy allows egress traffic to the world identities (everything outside the cluster) on port 80 and forces it through Cilium's Envoy proxy for Layer 7 visibility:
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-egress-visibility
  namespace: myns
spec:
  description: L7 policy
  egress:
  - toEntities:
    - world
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - {}
  endpointSelector: {}
```

### Host Firewall
Allow access to the API:
```yaml
apiVersion: "cilium.io/v2"
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: "control-plane-apiserver"
spec:
  description: "Allow Kubernetes API Server to Control Plane"
  nodeSelector:
    matchLabels:
      # Select the control plane node based on label
      node-role.kubernetes.io/control-plane: ""
  ingress:
  - toPorts:
    - ports:
      - port: "6443"
        protocol: TCP
```

Block all traffic:
```yaml
apiVersion: "cilium.io/v2"
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: "default-deny"
spec:
  description: "Block all unknown traffic to nodes"
  nodeSelector: {}
  ingress:
  - fromEntities:
    - cluster
```

Allow access to ssh only on the Control Plane:
```yaml
apiVersion: "cilium.io/v2"
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: "ssh"
spec:
  description: "SSH access on Control Plane"
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: ""
  ingress:
  - toPorts:
    - ports:
      - port: "22"
        protocol: TCP
```
