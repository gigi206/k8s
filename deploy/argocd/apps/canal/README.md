# Canal CNI

Canal combines **Flannel** (VXLAN overlay networking) with **Calico Felix** (network policy enforcement via iptables).

Canal is the **default CNI for RKE2** and is deployed automatically during cluster bootstrap.

## Architecture

| Component | Role |
|-----------|------|
| `calico-node` (Felix) | Programs network policies and routes via iptables |
| `kube-flannel` | Manages subnet allocation via flanneld (VXLAN overlay) |

Canal runs as a DaemonSet (`rke2-canal`) in the `kube-system` namespace.

## Key Differences vs Cilium/Calico

- Canal does **NOT** replace kube-proxy (uses iptables, not eBPF)
- Canal does **NOT** provide LB-IPAM, Gateway API, mutual auth, or Hubble
- Canal uses **Calico CRDs** for network policies (same as standalone Calico)
- Canal is the **simplest** CNI option in this project

## Configuration

### Global config (`config.yaml`)

```yaml
cni:
  primary: "canal"

features:
  canal:
    monitoring:
      enabled: true
    mtu: 1450
    backend: "vxlan"  # vxlan | wireguard
```

### Bootstrap (`configure_canal.sh`)

Creates a `HelmChartConfig` for `rke2-canal` with:
- `flannel.iface`: Network interface (eth1)
- `flannel.backend`: VXLAN or WireGuard
- `calico.mtu`: MTU for VXLAN overlay
- `calico.felix.prometheusMetricsEnabled`: Felix metrics on port 9091

## What This ApplicationSet Deploys

- **ServiceMonitor** for Felix metrics (port 9091)
- **PrometheusRules** for Canal alerting
- **GlobalNetworkPolicy** (3 default-deny policies):
  - `default-deny-external-egress` - Blocks world egress, allows cluster-internal
  - `default-deny-host-ingress` - Protects nodes (SSH, API, kubelet allowed)
  - `default-deny-pod-ingress` - Zero Trust pod-to-pod (explicit allows required)

## Network Policies

Canal uses the same Calico CRDs as standalone Calico:
- `crd.projectcalico.org/v1` `GlobalNetworkPolicy` (cluster-wide)
- `crd.projectcalico.org/v1` `NetworkPolicy` (namespace-scoped)

Per-app network policies reuse the existing `calico-*-policy.yaml` files via the `or` branching pattern in ApplicationSets.

## Compatible LoadBalancer Providers

- MetalLB
- LoxiLB
- kube-vip
- klipper
- Cilium LB: **NOT compatible** (requires `cni.primary=cilium`)

## Monitoring

Felix metrics only (no Typha in Canal):
- `felix_active_local_endpoints`
- `felix_int_dataplane_failures`
- `felix_resync_state`
- `felix_iptables_restore_errors`

## Troubleshooting

```bash
# Check Canal pods
kubectl get pods -n kube-system -l k8s-app=canal-node

# Check Felix logs
kubectl logs -n kube-system -l k8s-app=canal-node -c calico-node

# Check Flannel logs
kubectl logs -n kube-system -l k8s-app=canal-node -c kube-flannel

# Check network policies
kubectl get globalnetworkpolicies
kubectl get networkpolicies -A
```

## References

- [RKE2 Network Options](https://docs.rke2.io/networking/basic_network_options)
- [Calico Network Policy](https://docs.tigera.io/calico/latest/network-policy/)
- [rke2-canal Helm chart](https://github.com/rancher/rke2-charts)
