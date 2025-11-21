# Istio Ambient Mesh with ztunnel

## Overview

This ApplicationSet deploys **Istio Ambient Mesh** - a sidecar-free service mesh architecture that uses a shared node proxy (ztunnel) instead of per-pod sidecars.

**Key Benefits**:
- ✅ No sidecar injection required
- ✅ Reduced resource overhead (shared ztunnel per node vs sidecar per pod)
- ✅ Simpler operational model
- ✅ Transparent L4 encryption and authorization
- ✅ Optional L7 processing via waypoint proxies (not deployed by default)

**Istio Version**: 1.28.0 (full Ambient Mesh GA support)

## ⚠️ CRITICAL: Cilium CNI Prerequisites

Istio Ambient Mesh **requires specific Cilium configuration** to function correctly. These settings are **MANDATORY** and must be applied **BEFORE** deploying Istio.

### Required Cilium Configuration

The following Cilium settings are configured in `vagrant/scripts/configure_cilium.sh`:

#### 1. **`cni.exclusive: false`** ✅ REQUIRED

```yaml
cni:
  exclusive: false  # REQUIRED for Istio Ambient (CNI chaining with istio-cni)
```

**Why**: Cilium defaults to `exclusive: true`, which deletes all other CNI plugins. Istio Ambient requires the `istio-cni` plugin to coexist with Cilium for traffic redirection.

**Impact if missing**: Istio CNI plugin will be deleted by Cilium → pods cannot join the mesh.

#### 2. **`bpf.masquerade: false`** ✅ REQUIRED

```yaml
bpf:
  masquerade: false  # REQUIRED for Istio Ambient (BPF masq incompatible with Istio link-local IPs)
```

**Why**: Istio Ambient uses link-local IPs (169.254.x.x) for kubelet health probes. Cilium's eBPF masquerading does not handle these correctly, causing health check failures.

**Impact if missing**: Kubelet health probes fail → pods marked unhealthy → service disruption.

**Note**: With `bpf.masquerade: false`, Cilium falls back to iptables-based masquerading, which works correctly with Istio.

#### 3. **`socketLB.hostNamespaceOnly: true`** ✅ REQUIRED

```yaml
socketLB:
  hostNamespaceOnly: true  # REQUIRED for Istio Ambient (prevents socket LB conflicts with ztunnel)
```

**Why**: Cilium's socket-based load balancing (when `kubeProxyReplacement: true`) conflicts with ztunnel's traffic redirection. Limiting socket LB to the host namespace prevents interference with in-pod traffic.

**Impact if missing**: Traffic routing conflicts → intermittent connection failures.

#### 4. **`chainingMode: "none"`** ✅ OK (default)

```yaml
cni:
  chainingMode: "none"  # OK for non-AWS environments
```

**Why**: `chainingMode: "none"` is correct for standard Kubernetes environments. Only AWS EKS requires `chainingMode: "aws-cni"`.

### Verification

To verify Cilium configuration is correct:

```bash
# Check Cilium ConfigMap
kubectl get configmap cilium-config -n kube-system -o yaml | grep -E "cni-exclusive|bpf-masquerade|socketlb-host-namespace-only"

# Expected output:
# cni-exclusive: "false"
# bpf-masquerade: "false"
# socketlb-host-namespace-only: "true"
```

### CiliumClusterwideNetworkPolicy for Health Probes

This ApplicationSet deploys a `CiliumClusterwideNetworkPolicy` to allow Istio health probes:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-istio-health-probes
spec:
  ingress:
    - fromCIDR:
        - 169.254.7.127/32  # Istio's SNAT address for kubelet health probes
```

**Why**: If you have default-deny NetworkPolicies, kubelet health probes will be blocked because they originate from Istio's link-local SNAT address.

**Impact if missing**: Health checks fail with default-deny policies → pods marked unhealthy.

## Architecture

### Components Deployed

This ApplicationSet deploys 4 Istio components via separate Helm charts:

#### 1. **istio-base** (Wave 78.1 - CRDs)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/base`
- **Purpose**: Installs Istio CRDs (ServiceEntry, VirtualService, Gateway, etc.)
- **Namespace**: `istio-system`

#### 2. **istiod** (Wave 78.2 - Control Plane)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/istiod`
- **Purpose**: Istio control plane (configuration distribution, certificate management)
- **Replicas**:
  - Dev: 1
  - Prod: 3 (HA)
- **Key Config**: `PILOT_ENABLE_AMBIENT: "true"` (enables ambient profile)

#### 3. **istio-cni** (Wave 78.3 - CNI Plugin)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/cni`
- **Purpose**: CNI plugin for transparent traffic redirection (replaces init containers)
- **Deployment**: DaemonSet (runs on every node)
- **CNI Chaining**: Configured to chain with Cilium (`cniConfFileName: "10-cilium.conflist"`)

#### 4. **ztunnel** (Wave 78.4 - Ambient Data Plane)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/ztunnel`
- **Purpose**: Shared node proxy for L4 traffic processing (mTLS, telemetry, authorization)
- **Deployment**: DaemonSet (one per node)
- **Protocol**: HBONE (HTTP-Based Overlay Network Environment)

### Ambient Mesh Traffic Flow

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Pod A     │────────▶│  ztunnel    │────────▶│   Pod B     │
│ (workload)  │         │ (node proxy)│         │ (workload)  │
└─────────────┘         └─────────────┘         └─────────────┘
       │                       │                       ▲
       │                       │                       │
       │                ┌──────┴──────┐                │
       │                │   istiod    │                │
       │                │ (control)   │                │
       └───────────────▶└─────────────┘◀───────────────┘
                       (policy, certs)
```

1. **istio-cni** configures pod networking to redirect traffic to ztunnel
2. **ztunnel** intercepts traffic, applies mTLS, policies, and telemetry
3. **istiod** provides configuration and certificates to ztunnel
4. **Traffic flows**: Pod A → ztunnel (node A) → ztunnel (node B) → Pod B

## Deployment

### Wave Configuration

- **Wave**: 78 (after Cilium-Monitoring Wave 76)
- **Namespace**: `istio-system`
- **Dependencies**:
  - Cilium CNI (with required configuration)
  - Prometheus Operator CRDs (for monitoring)

### Installation

Istio is installed automatically via ArgoCD ApplicationSet:

```bash
# Check deployment status
kubectl get application -n argo-cd istio-dev

# Check Istio components
kubectl get pods -n istio-system

# Expected pods:
# istiod-xxx (1 or 3 replicas)
# istio-cni-node-xxx (DaemonSet - 1 per node)
# ztunnel-xxx (DaemonSet - 1 per node)
```

### Enabling Ambient Mesh for a Namespace

To add a namespace to the ambient mesh:

```bash
# Label the namespace
kubectl label namespace <namespace> istio.io/dataplane-mode=ambient

# Verify
kubectl get namespace <namespace> -o jsonpath='{.metadata.labels}'
```

Pods in labeled namespaces will automatically be added to the mesh (no sidecar injection or restart required).

### L7 Processing (Optional)

By default, Ambient Mesh only provides L4 features (mTLS, telemetry, authorization). For L7 features (traffic routing, retries, timeouts), deploy a **waypoint proxy**:

```bash
# Deploy a waypoint proxy for a namespace
istioctl waypoint apply --namespace <namespace>

# Verify
kubectl get gateway -n <namespace>
```

## Monitoring

### ServiceMonitors

This ApplicationSet deploys 3 ServiceMonitors for Prometheus metric collection:

- **istiod** (port 15014) - Control plane metrics (pilot, webhooks, config distribution)
- **istio-ingressgateway** (port 15020) - Gateway metrics (HTTP requests, latency, connections)
- **ztunnel** (port 15020) - Ambient data plane metrics (L4 traffic, mTLS, HBONE)

### PrometheusRules

This ApplicationSet deploys 18 PrometheusRules for monitoring Istio components:

#### istiod (Control Plane)
- ✅ **IstiodDown** (CRITICAL): No available replicas
- ✅ **IstiodPodCrashLooping** (CRITICAL): Frequent restarts
- ✅ **IstiodHighMemoryUsage** (HIGH): >85% memory usage
- ✅ **IstiodHighCPUUsage** (HIGH): >85% CPU usage
- ✅ **IstiodReplicaMismatch** (MEDIUM): Replica count mismatch

#### istio-cni
- ✅ **IstioCNIDown** (CRITICAL): No ready pods
- ✅ **IstioCNIPodNotReady** (HIGH): Pods missing on some nodes

#### ztunnel (Data Plane)
- ✅ **ZtunnelDown** (CRITICAL): No ready pods
- ✅ **ZtunnelPodNotReady** (HIGH): Pods missing on some nodes
- ✅ **ZtunnelPodCrashLooping** (CRITICAL): Frequent restarts
- ✅ **ZtunnelHighMemoryUsage** (WARNING): >85% memory usage
- ✅ **ZtunnelHighCPUUsage** (WARNING): >85% CPU usage

#### istio-ingressgateway (Ingress Gateway)
- ✅ **IstioIngressGatewayDown** (CRITICAL): No available replicas
- ✅ **IstioIngressGatewayPodNotReady** (HIGH): Pods not ready
- ✅ **IstioIngressGatewayHighErrorRate** (HIGH): >5% error rate (HTTP 5xx)
- ✅ **IstioIngressGatewayHighLatency** (HIGH): P99 latency >5s
- ✅ **IstioIngressGatewayHighMemoryUsage** (WARNING): >85% memory usage

### Grafana Dashboards

Istio provides official Grafana dashboards (not auto-deployed by this ApplicationSet):

- **Istio Control Plane Dashboard**: istiod metrics, pilot performance
- **Istio Mesh Dashboard**: Service-to-service traffic, success rates
- **Istio Service Dashboard**: Per-service metrics, latency, errors
- **Istio Workload Dashboard**: Per-workload metrics

To import dashboards manually:
```bash
# Download from https://grafana.com/grafana/dashboards/
# Search for "Istio" and import the dashboard JSON
```

## Troubleshooting

### Pods Not Joining Mesh

**Symptom**: Pods in labeled namespace don't have ambient mesh features.

**Checks**:
1. Verify namespace label:
   ```bash
   kubectl get namespace <namespace> -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}'
   # Should output: ambient
   ```

2. Check istio-cni is running:
   ```bash
   kubectl get pods -n istio-system -l k8s-app=istio-cni-node
   ```

3. Check ztunnel is running:
   ```bash
   kubectl get pods -n istio-system -l app=ztunnel
   ```

4. Check pod annotations (ambient pods get special annotations):
   ```bash
   kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.metadata.annotations}'
   ```

### Health Probes Failing

**Symptom**: Pods marked unhealthy after enabling ambient.

**Cause**: Cilium BPF masquerading or missing NetworkPolicy for 169.254.7.127/32.

**Solution**:
1. Verify Cilium config (see Prerequisites section above)
2. Check CiliumClusterwideNetworkPolicy is deployed:
   ```bash
   kubectl get ciliumclusterwidenetworkpolicy allow-istio-health-probes
   ```

### CNI Plugin Conflicts

**Symptom**: Istio CNI pod crash loops or is missing.

**Cause**: `cni.exclusive: true` in Cilium (Cilium deleted istio-cni).

**Solution**: Verify Cilium configuration (see Prerequisites section above).

### ztunnel Connection Errors

**Symptom**: `connection refused` or `connection reset` errors in logs.

**Checks**:
1. Verify ztunnel is running on all nodes:
   ```bash
   kubectl get daemonset ztunnel -n istio-system
   ```

2. Check ztunnel logs:
   ```bash
   kubectl logs -n istio-system daemonset/ztunnel -c istio-proxy
   ```

3. Verify socket LB configuration in Cilium:
   ```bash
   kubectl get configmap cilium-config -n kube-system -o yaml | grep socketlb-host-namespace-only
   # Should be: "true"
   ```

### istiod Not Starting

**Symptom**: istiod pod crash loops.

**Checks**:
1. Check logs:
   ```bash
   kubectl logs -n istio-system deployment/istiod
   ```

2. Verify CRDs are installed:
   ```bash
   kubectl get crd | grep istio.io
   ```

3. Check resource limits (might need more memory in prod):
   ```bash
   kubectl describe pod -n istio-system <istiod-pod>
   ```

### Kubernetes Ingress HTTPS Not Working

**Symptom**: Kubernetes Ingress resources work in HTTP but fail in HTTPS (connection reset).

**Cause**: Istio Ingress Gateway cannot read TLS secrets from other namespaces. This is a known limitation when using Kubernetes Ingress with Istio 1.28.0.

**Solution**: See the comprehensive troubleshooting guide:
- **[TROUBLESHOOTING-INGRESS.md](./TROUBLESHOOTING-INGRESS.md)** - Detailed analysis and 5 solution options

**Quick Summary**:
- Root cause: TLS secrets created by cert-manager in application namespaces (kube-system, monitoring, etc.) are inaccessible to Istio Ingress Gateway in istio-system
- Recommended short-term: Use wildcard certificate
- Recommended long-term: Migrate to Kubernetes Gateway API + HTTPRoute

## Configuration

### Environment-Specific Settings

- **Dev** (`config/dev.yaml`):
  - 1 istiod replica
  - Minimal resources
  - Auto-sync enabled

- **Prod** (`config/prod.yaml`):
  - 3 istiod replicas (HA)
  - Higher resource limits
  - Manual sync (for controlled updates)

### Customization

To modify Istio configuration:

1. Edit `config/dev.yaml` or `config/prod.yaml`
2. Commit and push to Git
3. ArgoCD auto-syncs (dev) or manually sync (prod)

Example - increase istiod replicas:
```yaml
# config/prod.yaml
istio:
  pilot:
    replicas: 5  # Increase from 3 to 5
```

## References

- **Istio Ambient Mesh Docs**: https://istio.io/latest/docs/ambient/
- **Platform Prerequisites**: https://istio.io/latest/docs/ambient/install/platform-prerequisites/
- **Cilium Integration**: https://docs.cilium.io/en/latest/network/servicemesh/istio/
- **ztunnel Architecture**: https://istio.io/latest/blog/2022/introducing-ambient-mesh/
- **HBONE Protocol**: https://github.com/istio/ztunnel/blob/master/ARCHITECTURE.md
