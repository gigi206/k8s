# Istio Ambient Mesh with ztunnel

## Overview

This ApplicationSet deploys **Istio Ambient Mesh** - a sidecar-free service mesh architecture that uses a shared node proxy (ztunnel) instead of per-pod sidecars.

**Key Benefits**:
- ✅ No sidecar injection required
- ✅ Reduced resource overhead (shared ztunnel per node vs sidecar per pod)
- ✅ Simpler operational model
- ✅ Transparent L4 encryption and authorization
- ✅ Optional L7 processing via waypoint proxies for HTTP metrics and advanced routing

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

#### 1. **istio-base** ( - CRDs)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/base`
- **Purpose**: Installs Istio CRDs (ServiceEntry, VirtualService, Gateway, etc.)
- **Namespace**: `istio-system`

#### 2. **istiod** ( - Control Plane)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/istiod`
- **Purpose**: Istio control plane (configuration distribution, certificate management)
- **Replicas**:
 - Dev: 1
 - Prod: 3 (HA)
- **Key Config**: `PILOT_ENABLE_AMBIENT: "true"` (enables ambient profile)

#### 3. **istio-cni** ( - CNI Plugin)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/cni`
- **Purpose**: CNI plugin for transparent traffic redirection (replaces init containers)
- **Deployment**: DaemonSet (runs on every node)
- **CNI Chaining**: Configured to chain with Cilium (`cniConfFileName: "10-cilium.conflist"`)

#### 4. **ztunnel** ( - Ambient Data Plane)
- **Chart**: `https://istio-release.storage.googleapis.com/charts/ztunnel`
- **Purpose**: Shared node proxy for L4 traffic processing (mTLS, telemetry, authorization)
- **Deployment**: DaemonSet (one per node)
- **Protocol**: HBONE (HTTP-Based Overlay Network Environment)

#### 5. **Kiali** (Service Mesh Observability)
- **Chart**: `https://kiali.org/helm-charts/kiali-server`
- **Purpose**: Service mesh visualization, traffic analysis, and configuration validation
- **Namespace**: `istio-system`
- **Accès**: https://kiali.k8s.lan
- **Authentication**: OIDC via Keycloak (auto-login)

**Fonctionnalités Kiali**:
- Visualisation de la topologie du mesh
- Analyse du trafic en temps réel
- Validation de la configuration Istio
- Gestion des VirtualServices, DestinationRules, etc.
- Intégration Prometheus et Grafana

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

- **Wave**: 40 (service mesh foundation, before istio-gateway )
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

## Waypoint Proxy (L7 Processing)

By default, Ambient Mesh only provides L4 features via **ztunnel** (mTLS, TCP telemetry, L4 authorization). For L7 features, deploy a **waypoint proxy**.

### Why Waypoint?

| Feature | ztunnel (L4) | Waypoint (L7) |
|---------|--------------|---------------|
| mTLS encryption | ✅ | ✅ |
| TCP metrics (`istio_tcp_*`) | ✅ | ✅ |
| **HTTP metrics** (`istio_requests_total`) | ❌ | ✅ |
| HTTP routing (path, headers) | ❌ | ✅ |
| Retries, timeouts, circuit breaking | ❌ | ✅ |
| L7 authorization policies | ❌ | ✅ |
| Request tracing | ❌ | ✅ |

### Waypoint Configuration

Waypoints are deployed per-namespace using a Kubernetes Gateway resource with the `istio-waypoint` GatewayClass.

#### Manual Deployment

```bash
# Deploy a waypoint proxy for a namespace
istioctl waypoint apply --namespace <namespace>

# Or create the Gateway manually
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: <namespace>
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
   - name: mesh
      port: 15008
      protocol: HBONE
EOF

# Verify
kubectl get gateway -n <namespace>
kubectl get deploy -n <namespace> waypoint
```

### Configuring Waypoint Replicas

The default number of waypoint replicas is controlled globally via istiod environment variable.

#### Global Default (per environment)

```yaml
# config/dev.yaml
istio:
  pilot:
    env:
      PILOT_DEFAULT_WAYPOINT_REPLICAS: "1"  # Dev: single replica

# config/prod.yaml
istio:
  pilot:
    env:
      PILOT_DEFAULT_WAYPOINT_REPLICAS: "2"  # Prod: HA
```

#### Per-Waypoint Override

To override replicas for a specific waypoint, use an annotation on the Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: bookinfo
  annotations:
    proxy.istio.io/replicas: "3"  # Override for this waypoint
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
   - name: mesh
      port: 15008
      protocol: HBONE
```

### Waypoint Metrics

Waypoint exposes metrics on port 15090 via `/stats/prometheus`. The PodMonitor in `kustomize/podmonitor.yaml` scrapes these metrics.

**Key metrics from waypoint:**
- `istio_requests_total` - HTTP request count by response code, method, path
- `istio_request_duration_milliseconds` - Request latency histogram
- `istio_request_bytes` / `istio_response_bytes` - Request/response sizes

**Reporter label:** Waypoint metrics use `reporter="waypoint"` (vs `reporter="source"` or `reporter="destination"` for sidecars)

## Access Logging (Log-to-Trace Correlation)

### Overview

Envoy access logs can be enabled per-namespace to capture HTTP request details including trace IDs. This enables **log-to-trace correlation** in Grafana (Loki → Tempo).

### Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        meshConfig (global)                                   │
│  extensionProviders:                                                         │
│   - name: access-log-json         # Provider definition                     │
│      envoyFileAccessLog:                                                     │
│        path: /dev/stdout                                                     │
│        logFormat:                                                            │
│          labels: { trace_id, span_id, method, path, response_code, ... }     │
└──────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │  Reference provider by name
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Telemetry (per namespace)                                │
│  namespace: my-app                                                           │
│  spec:                                                                       │
│    accessLogging:                                                            │
│     - providers:                                                            │
│         - name: access-log-json   # Enable for this namespace only          │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Benefits**:
- ✅ **Namespace-level control** - Enable only where needed (reduces log volume)
- ✅ **JSON format with trace_id** - Enables log-to-trace correlation
- ✅ **No global overhead** - Provider defined globally, activation per namespace

### Enabling Access Logs for a Namespace

**Prerequisites**:
- Namespace must have a **waypoint proxy** for L7 logging (ztunnel only does L4)
- Namespace must be labeled with `istio.io/dataplane-mode=ambient`

**Step 1**: Create waypoint proxy (if not already present):
```bash
istioctl waypoint apply --namespace my-namespace
# Or via kubectl:
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: my-namespace
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
   - name: mesh
      port: 15008
      protocol: HBONE
EOF
```

**Step 2**: Create Telemetry resource to enable access logging:
```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: access-logging
  namespace: my-namespace
spec:
  accessLogging:
   - providers:
       - name: access-log-json
```

**Step 3**: Verify access logs are being generated:
```bash
kubectl logs -n my-namespace -l gateway.networking.k8s.io/gateway-name=waypoint --tail=5
```

### Log Format

The `access-log-json` provider outputs JSON logs with the following fields:

```json
{
  "timestamp": "2025-12-10T21:36:54.464Z",
  "method": "GET",
  "path": "/api/list",
  "protocol": "HTTP/1.1",
  "response_code": 200,
  "response_flags": "-",
  "bytes_received": 0,
  "bytes_sent": 4513,
  "duration_ms": 1,
  "upstream_host": "envoy://connect_originate/10.42.0.74:8080",
  "upstream_cluster": "inbound-vip|80|http|web-svc.emojivoto.svc.cluster.local;",
  "trace_id": "225944ea496241841e6f4ae19e48129f",
  "span_id": "8fd1f53441eada43",
  "authority": "web-svc.emojivoto:80",
  "user_agent": "Go-http-client/1.1",
  "request_id": "2322499c-d24f-9200-b246-9fb30fab21d6"
}
```

### Log-to-Trace Correlation in Grafana

With access logs containing `trace_id`, you can navigate from logs to traces:

1. **In Grafana Explore** → Select Loki datasource
2. Query: `{namespace="my-namespace"} | json`
3. Click on a log line with a `trace_id`
4. Click **"View Trace"** button to jump to Tempo

**Configuration**: The Loki datasource has `derivedFields` configured to extract `trace_id` and link to Tempo.

### Disabling Access Logs

To disable access logs for a namespace:
```bash
kubectl delete telemetry access-logging -n my-namespace
```

### Comparison: Global vs Namespace-Level

| Approach | Scope | Configuration |
|----------|-------|---------------|
| `meshConfig.accessLogFile` | Global (all proxies) | Define in istiod Helm values |
| `Telemetry` API | Per namespace | Create Telemetry resource per namespace |

**Recommendation**: Use namespace-level Telemetry for selective logging to minimize log volume and storage costs.

## Distributed Tracing

### Overview

Istio Ambient Mesh provides distributed tracing via OpenTelemetry. Traces are generated by the **Gateway** and **Waypoint proxies**, then sent to Tempo.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         External Traffic                                     │
│                                                                              │
│   Client ──────► Gateway ──────► Waypoint ──────► Application               │
│                    │                │                                        │
│                    │ generates      │ propagates                             │
│                    │ trace_id       │ trace_id                               │
│                    ▼                ▼                                        │
│                 ┌─────────────────────┐                                      │
│                 │       Tempo         │                                      │
│                 │   (OTLP :4317)      │                                      │
│                 └─────────────────────┘                                      │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         Internal Traffic                                     │
│                                                                              │
│   Pod A ──────► Waypoint ──────► Pod B                                      │
│                    │                                                         │
│                    │ generates                                               │
│                    │ trace_id                                                │
│                    ▼                                                         │
│                 ┌─────────────────────┐                                      │
│                 │       Tempo         │                                      │
│                 └─────────────────────┘                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Configuration

Tracing is configured in `meshConfig`:

```yaml
meshConfig:
  enableTracing: true
  defaultProviders:
    tracing:
     - otel
  extensionProviders:
   - name: otel
      opentelemetry:
        service: tempo.tempo.svc.cluster.local
        port: 4317
  defaultConfig:
    tracing:
      sampling: 100  # 100% sampling (adjust for production)
```

### Trace ID in Access Logs

Access logs use `%TRACE_ID%` to capture the Envoy-generated trace ID:

```yaml
logFormat:
  labels:
    trace_id: "%TRACE_ID%"  # Envoy-generated trace ID
    span_id: "%REQ(X-B3-SPANID)%"
```

**Important**: Do NOT use `%REQ(X-B3-TRACEID)%` as it reads from incoming request headers (often empty for external traffic).

| Variable | Source | Use Case |
|----------|--------|----------|
| `%TRACE_ID%` | Envoy tracing context | ✅ Always has value |
| `%REQ(X-B3-TRACEID)%` | Incoming request header | ❌ Often empty |

### Log-to-Trace Correlation

With access logs containing `trace_id`, you can navigate from Loki to Tempo:

1. **Query Loki**:
   ```
   {namespace="my-namespace", pod=~".*waypoint.*"} | json | trace_id != ""
   ```

2. **Click on a log entry** with `trace_id`

3. **Click "View Trace"** to open the trace in Tempo

### Trace Coverage

| Traffic Type | Trace Generated By | trace_id in Logs |
|--------------|-------------------|------------------|
| External → App | Gateway | ✅ |
| Internal Pod → Pod | Waypoint | ✅ |
| App errors (application logs) | Application (if instrumented) | Varies |

**Note**: Application logs only contain trace headers if the application is instrumented for tracing. The **access logs** from Gateway/Waypoint always have `trace_id`.

### Verifying Traces

```bash
# Check traces in Tempo for a service
kubectl exec -n tempo tempo-0 -- wget -qO- \
  'http://localhost:3100/api/search?q={.service.name=~".*my-service.*"}&limit=5' | jq '.traces'

# Verify a specific trace exists
kubectl exec -n tempo tempo-0 -- wget -qO- \
  "http://localhost:3100/api/traces/<trace_id>" | jq '.batches | length'
```

### Troubleshooting Tracing

**trace_id is null in access logs**:
- Verify using `%TRACE_ID%` not `%REQ(X-B3-TRACEID)%`
- Restart the gateway/waypoint after config changes
- Check `meshConfig.enableTracing: true`

**Traces not appearing in Tempo**:
- Verify Tempo is accessible: `tempo.tempo.svc.cluster.local:4317`
- Check sampling rate: `meshConfig.defaultConfig.tracing.sampling`
- Verify the proxy has tracing configured:
  ```bash
  kubectl exec -n <namespace> <pod> -- pilot-agent request GET config_dump | grep -i opentelemetry
  ```

## Monitoring

### ServiceMonitors and PodMonitors

This ApplicationSet deploys monitors for Prometheus metric collection in `kustomize/podmonitor.yaml`:

#### ServiceMonitors
- **istiod** (port 15014) - Control plane metrics (pilot, webhooks, config distribution)
- **istio-ingressgateway** (port 15020) - Gateway metrics (HTTP requests, latency, connections)

#### PodMonitors
PodMonitors are used for components without a Service (DaemonSets, dynamically created pods):

| Monitor | Selector | Port | Metrics |
|---------|----------|------|---------|
| `ztunnel` | `app: ztunnel` | 15020 | L4 traffic, mTLS, HBONE connections |
| `istio-sidecar` | `security.istio.io/tlsMode` exists | 15090 | Sidecar proxy metrics (if any) |
| `istio-waypoint` | `gateway.networking.k8s.io/gateway-class-name: istio-waypoint` | 15090 | HTTP metrics (`istio_requests_total`) |

**Note**: The waypoint PodMonitor uses `namespaceSelector.any: true` to scrape waypoints from all namespaces (waypoints are deployed per-namespace)

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

This ApplicationSet deploys 6 Grafana dashboards via ConfigMaps in `kustomize/` directory.

#### Dashboard Sources

The dashboards are **official Istio dashboards** from the Istio repository, modified to support **Ambient mode waypoint metrics**.

| Dashboard | Source | Modifications |
|-----------|--------|---------------|
| Istio Mesh Dashboard | [istio/istio](https://github.com/istio/istio/tree/master/manifests/addons/dashboards) | None (L4 compatible) |
| Istio Service Dashboard | Official Istio | `reporter=~"destination\|waypoint"` |
| Istio Workload Dashboard | Official Istio | `reporter=~"source\|waypoint"` |
| Istio Performance Dashboard | Official Istio | `reporter=~"source\|waypoint"` |
| Istio Control Plane Dashboard | Official Istio | None |
| Istio Ztunnel Dashboard | Official Istio | None (ztunnel-specific) |

**Original dashboard sources:**
- GitHub: https://github.com/istio/istio/tree/master/manifests/addons/dashboards
- Grafana.com: Search "Istio" at https://grafana.com/grafana/dashboards/

#### Waypoint Modifications

Standard Istio dashboards use `reporter="source"` or `reporter="destination"` in their PromQL queries. These work for sidecar-based deployments but miss waypoint metrics in Ambient mode.

**Modifications made:**
1. **Queries**: Changed `reporter="source"` → `reporter=~"source|waypoint"` and `reporter="destination"` → `reporter=~"destination|waypoint"`
2. **Reporter variable**: Added `waypoint` option to the `qrep` (Reporter) dropdown filter

This allows dashboards to display both traditional sidecar metrics AND waypoint metrics.

#### Dashboard Files

```
kustomize/
├── grafana-istio-mesh-dashboard.yaml
├── grafana-istio-service-dashboard.yaml      # Modified for waypoint
├── grafana-istio-workload-dashboard.yaml     # Modified for waypoint
├── grafana-istio-performance-dashboard.yaml  # Modified for waypoint
├── grafana-istio-control-plane-dashboard.yaml
└── grafana-istio-ztunnel-dashboard.yaml      # Ztunnel-specific (Ambient)
```

#### Updating Dashboards

To update dashboards from upstream:

1. Download the latest JSON from [istio/istio](https://github.com/istio/istio/tree/master/manifests/addons/dashboards)
2. Apply waypoint modifications:
  - Replace `reporter=\"source\"` with `reporter=~\"source|waypoint\"`
  - Replace `reporter=\"destination\"` with `reporter=~\"destination|waypoint\"`
  - Add `waypoint` to the `qrep` variable options
3. Wrap in ConfigMap YAML with `grafana_dashboard: "1"` label
4. Commit and push

## Kiali - Service Mesh Observability

### Accès

**URL**: https://kiali.k8s.lan

**Authentification OIDC (Keycloak)**:

L'accès web utilise l'authentification OIDC:
1. Naviguer vers https://kiali.k8s.lan
2. Redirection automatique vers Keycloak
3. S'authentifier avec votre compte Keycloak
4. Retour automatique vers Kiali

**Configuration**:
```yaml
# config/dev.yaml
kiali:
  auth:
    strategy: "openid"
    openid:
      clientId: "kiali"
      issuerUri: "https://keycloak.k8s.lan/realms/k8s"
      scopes: ["openid", "email", "profile", "groups"]
      usernameClaim: "preferred_username"
      disableRbac: true  # Dev: tous les utilisateurs ont accès complet
```

### Intégration Grafana

Kiali s'intègre avec Grafana pour afficher les dashboards directement depuis l'interface:

**Architecture**:
```
Kiali Pod                              Grafana Pod
+-----------------------+              +------------------+
| Mounted Secrets:      |    HTTP      |                  |
| - grafana-username    |------------->| Basic Auth       |
| - grafana-password    |              | (admin/password) |
+-----------------------+              +------------------+
```

Les credentials Grafana sont synchronisés via ExternalSecrets:
- `kiali-grafana-username` → mounted at `/kiali-override-secrets/grafana-username/value.txt`
- `kiali-grafana-password` → mounted at `/kiali-override-secrets/grafana-password/value.txt`

### Dépannage Kiali

**OIDC redirect vers mauvais port**:
Si la redirection OIDC utilise le port 20001 au lieu de 443:
```yaml
server:
  web_fqdn: kiali.k8s.lan
  web_port: "443"
  web_schema: https
```

**Grafana non accessible depuis Kiali**:
1. Vérifier les ExternalSecrets:
   ```bash
   kubectl get externalsecret -n istio-system | grep grafana
   ```
2. Vérifier les secrets montés:
   ```bash
   kubectl exec -n istio-system deployment/kiali -- ls -la /kiali-override-secrets/
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

### Istio Ambient Mesh
- **Istio Ambient Mesh Docs**: https://istio.io/latest/docs/ambient/
- **Platform Prerequisites**: https://istio.io/latest/docs/ambient/install/platform-prerequisites/
- **ztunnel Architecture**: https://istio.io/latest/blog/2022/introducing-ambient-mesh/
- **HBONE Protocol**: https://github.com/istio/ztunnel/blob/master/ARCHITECTURE.md

### Waypoint Proxy
- **Waypoint Overview**: https://istio.io/latest/docs/ambient/usage/waypoint/
- **Waypoint Configuration**: https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/#ProxyConfig
- **Gateway API for Waypoints**: https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/

### Grafana Dashboards
- **Official Istio Dashboards**: https://github.com/istio/istio/tree/master/manifests/addons/dashboards
- **Grafana Dashboard Library**: https://grafana.com/grafana/dashboards/ (search "Istio")

### Cilium Integration
- **Cilium + Istio**: https://docs.cilium.io/en/latest/network/servicemesh/istio/
