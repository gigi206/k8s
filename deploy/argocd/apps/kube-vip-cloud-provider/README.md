# kube-vip-cloud-provider

## Overview

kube-vip-cloud-provider is an IPAM controller that allocates IP addresses to Services of type LoadBalancer from configured IP pools. It works together with kube-vip which handles the actual L2 ARP announcements.

## Architecture

```
┌─────────────────────────────┐    ┌─────────────────────────────┐
│  kube-vip-cloud-provider    │    │         kube-vip            │
│                             │    │                             │
│  - IPAM Controller          │───▶│  - Annonce ARP/BGP          │
│  - ConfigMap pools          │    │  - Control Plane VIP        │
│  - Alloue IPs aux Services  │    │  - Service LoadBalancer VIP │
└─────────────────────────────┘    └─────────────────────────────┘
```

**Flow:**
1. Service created with `type: LoadBalancer`
2. kube-vip-cloud-provider allocates IP from ConfigMap pool
3. kube-vip-cloud-provider annotates Service with `kube-vip.io/loadbalancerIPs`
4. kube-vip (with `svc_enable=true`) detects annotation and announces IP via ARP

## Configuration

### IP Pool Configuration

IP pools are configured via ConfigMap `kubevip` in `kube-system` namespace:

```yaml
data:
  # Global pool (fallback for all namespaces)
  range-global: "192.168.121.200-192.168.121.250"

  # Namespace-specific pools (optional)
  cidr-production: "10.0.1.0/24"
  range-development: "10.0.2.1-10.0.2.50"
```

The pool is automatically populated from `features.loadBalancer.pools.default.range` in config.yaml.

### Static IP Assignment

Request a specific IP using the annotation:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    kube-vip.io/loadbalancerIPs: "192.168.121.201"
spec:
  type: LoadBalancer
  ports:
    - port: 80
```

## Prerequisites

- `features.loadBalancer.provider: "kube-vip"` in config.yaml
- kube-vip deployed with `svc_enable=true` (automatic when provider=kube-vip)

## Comparison with Other Providers

| Feature | kube-vip-cloud-provider | MetalLB |
|---------|-------------------------|---------|
| Configuration | ConfigMap | CRDs (IPAddressPool, L2Advertisement) |
| CRDs required | No | Yes |
| L2/BGP handling | Via kube-vip | Integrated (speaker) |
| Complexity | Lower | Higher |

## Troubleshooting

### Service not getting an IP

1. Check kube-vip-cloud-provider logs:
   ```bash
   kubectl logs -n kube-system -l app.kubernetes.io/name=kube-vip-cloud-provider
   ```

2. Verify ConfigMap exists:
   ```bash
   kubectl get configmap kubevip -n kube-system -o yaml
   ```

3. Check if kube-vip has `svc_enable=true`:
   ```bash
   kubectl get ds kube-vip -n kube-system -o yaml | grep -A1 svc_enable
   ```

### IP not reachable

1. Check kube-vip logs for ARP announcements:
   ```bash
   kubectl logs -n kube-system -l app=kube-vip
   ```

2. Verify the IP is on the correct interface/VLAN

## References

- [kube-vip-cloud-provider Documentation](https://kube-vip.io/docs/usage/cloud-provider/)
- [GitHub Repository](https://github.com/kube-vip/kube-vip-cloud-provider)
- [Helm Chart](https://artifacthub.io/packages/helm/kube-vip/kube-vip-cloud-provider)
