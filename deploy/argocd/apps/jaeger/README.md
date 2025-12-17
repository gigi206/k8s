# Jaeger - Distributed Tracing

Jaeger provides distributed tracing for monitoring and troubleshooting microservices-based architectures.

## Overview

- **Wave**: 77
- **Namespace**: `jaeger`
- **Helm Chart**: [jaegertracing/jaeger](https://jaegertracing.github.io/helm-charts)
- **UI Access**: `https://jaeger.<domain>` (via HTTPRoute)

## Deployment Modes

### Dev Environment (All-in-One)

Single pod deployment with embedded Badger storage:
- Collector, Query, and Agent in one container
- Ephemeral in-memory storage (data lost on restart)
- Suitable for development and testing

### Prod Environment

Separate components for high availability:
- Dedicated Collector pods
- Dedicated Query pods
- External storage backend (Elasticsearch/Cassandra)

## Istio Ambient Mode Integration

### How Tracing Works

Istio is configured to send traces to Jaeger via the Zipkin protocol:

```yaml
# In Istio meshConfig
extensionProviders:
  - name: zipkin
    zipkin:
      service: jaeger-collector.jaeger.svc.cluster.local
      port: 9411
```

### Known Limitations with Ambient Mode

> **Important**: Distributed tracing in Istio Ambient mode has architectural limitations compared to Sidecar mode.

| Component | Generates Spans | Reason |
|-----------|-----------------|--------|
| istio-gateway | Yes | L7 proxy with full tracing support |
| Waypoint proxy | Limited | Telemetry API support still evolving |
| ztunnel | No | L4 only, cannot generate HTTP spans |
| Application pods | No | No sidecar proxy in Ambient mode |

#### Architecture Comparison

**Sidecar Mode** (full tracing):
```
Client -> Sidecar (span) -> Sidecar (span) -> Server
         = 2 spans per hop
```

**Ambient Mode** (limited tracing):
```
Client -> ztunnel (L4, no span) -> ztunnel (L4, no span) -> Server
         = 0 spans for east-west traffic (unless via waypoint)
```

#### What You'll See in Jaeger

- **Ingress traffic**: Full traces from `istio-gateway-istio.istio-system`
- **East-west traffic**: Headers propagated (X-B3-*) but no spans from mesh components

#### Workarounds

1. **For application-level tracing**: Instrument applications with OpenTelemetry SDK
2. **For ingress traffic**: Traces work normally via the gateway
3. **Future improvement**: Istio team is working on enhanced waypoint tracing support

### References

- [Istio Issue #56467 - Traces in ambient and sidecar mode](https://github.com/istio/istio/issues/56467) - Confirmed as expected behavior
- [Istio Issue #55843 - Ambient tracing issues](https://github.com/istio/istio/issues/55843)
- [Ambient Mesh - Enable Tracing](https://ambientmesh.io/docs/observability/tracing/)
- [Istio Telemetry API](https://istio.io/latest/docs/tasks/observability/distributed-tracing/telemetry-api/)

## Configuration

### Feature Flags

Enable Jaeger via `config/config.yaml`:

```yaml
features:
  tracing:
    enabled: true
    provider: "jaeger"
```

### Istio Tracing Settings

Configure in `apps/istio/config/dev.yaml`:

```yaml
istio:
  tracing:
    sampling: 100  # 100% sampling for dev, 1% for prod
    zipkinAddress: "jaeger-collector.jaeger.svc.cluster.local:9411"
```

## Verification

```bash
# Check Jaeger pods
kubectl get pods -n jaeger

# Access Jaeger UI
kubectl port-forward -n jaeger svc/jaeger-query 16686:16686
# Open http://localhost:16686

# Check available services in Jaeger
curl -s http://localhost:16686/api/services | jq '.data'

# Generate test traffic and verify traces
curl -H "Host: httpbin.k8s.lan" http://<gateway-ip>/get
```

## Kiali Integration

Kiali automatically discovers Jaeger and displays traces in the service graph:

```yaml
# In Istio/Kiali config
external_services:
  tracing:
    enabled: true
    in_cluster_url: http://jaeger-query.jaeger:16686
    url: https://jaeger.<domain>
```

## Monitoring

### Prometheus Alerts

9 alertes sont configurées pour Jaeger :

**Disponibilité**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| JaegerAllInOneDown | critical | All-in-one indisponible (5m) |
| JaegerCollectorDown | critical | Collector indisponible (5m) |
| JaegerQueryDown | critical | Query indisponible (5m) |

**Santé des Pods**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| JaegerPodCrashLooping | critical | Pod en restart loop (10m) |
| JaegerPodNotReady | warning | Pod non ready (10m) |

**Performance**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| JaegerSpansDropped | warning | Spans perdus (10m) |
| JaegerCollectorQueueLength | warning | Queue > 1000 (10m) |
| JaegerStorageErrors | warning | Erreurs stockage (5m) |

**Waypoint** (Istio Ambient):

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| IstioWaypointNotReady | warning | Waypoint proxy non ready (10m) |

## Troubleshooting

### Pas de traces

```bash
# Vérifier que Jaeger reçoit des spans
kubectl logs -n jaeger -l app.kubernetes.io/name=jaeger | grep -i span

# Tester l'API
kubectl port-forward -n jaeger svc/jaeger-query 16686:16686
curl http://localhost:16686/api/services
```

### Traces incomplètes

Voir la section "Known Limitations with Ambient Mode" ci-dessus.

## References

- [Jaeger Documentation](https://www.jaegertracing.io/docs/)
- [Jaeger Helm Chart](https://github.com/jaegertracing/helm-charts)
