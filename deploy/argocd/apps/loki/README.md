# Loki - Log Aggregation

Loki is a horizontally-scalable, highly-available log aggregation system inspired by Prometheus.

## Overview

- **Wave**: 73
- **Namespace**: `loki`
- **Helm Chart**: [grafana/loki](https://grafana.github.io/helm-charts)

## Deployment Modes

### Dev Environment (SingleBinary)

Single pod deployment suitable for development:
- All components in one container
- Filesystem storage
- Minimal resource requirements

### Prod Environment (Distributed)

Scalable deployment for production:
- Separate read/write paths
- Object storage backend (S3/MinIO)
- Horizontal scaling

## Log Collection

Loki requires a log collector to push logs. This project supports:

- **Alloy** (recommended): Grafana's OpenTelemetry collector
- **Promtail**: Traditional Loki agent

Configure the collector in `config.yaml`:

```yaml
features:
  logging:
    enabled: true
    loki:
      enabled: true
      collector: alloy  # or promtail
```

## Integration with Grafana

Loki is automatically configured as a datasource in Grafana (via prometheus-stack). Use LogQL to query logs:

```logql
{namespace="my-namespace"} |= "error"
```

## Storage Backends

### Filesystem (Dev)

Default for development, uses local PVC storage.

### S3/MinIO (Prod)

For production, configure object storage:

```yaml
loki:
  storage:
    type: s3
    s3:
      endpoint: minio.minio.svc:9000
      bucketName: loki
```

## Monitoring

### Prometheus Alerts

8 alertes sont configurées pour Loki :

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| LokiDown | critical | Loki indisponible (5m) |
| LokiPodNotReady | critical | Pod Loki non ready (5m) |
| LokiHighRequestLatency | high | Latence p99 > 5s (10m) |
| LokiIngesterErrors | high | Erreurs flush ingester (5m) |
| LokiDiskAlmostFull | warning | PVC > 80% utilisé (10m) |
| LokiHighMemoryUsage | warning | Mémoire > 85% (10m) |
| LokiQueryErrors | warning | Taux erreurs queries > 5% (10m) |
| LokiIngesterStreamsLimit | medium | Limite streams > 80% (10m) |

### Métriques clés

```promql
# Ingestion
rate(loki_distributor_bytes_received_total[5m])
loki_ingester_memory_streams

# Queries
histogram_quantile(0.99, rate(loki_request_duration_seconds_bucket[5m]))
rate(loki_logql_querystats_latency_seconds_count[5m])

# Storage
loki_ingester_chunks_stored_total
```

## Troubleshooting

### Loki ne démarre pas

```bash
kubectl get pods -n loki
kubectl logs -n loki -l app.kubernetes.io/name=loki
kubectl describe pod -n loki -l app.kubernetes.io/name=loki
```

### Logs non visibles dans Grafana

```bash
# Vérifier qu'Alloy envoie des logs
kubectl logs -n alloy -l app.kubernetes.io/name=alloy | grep -i loki

# Tester l'API Loki
kubectl port-forward -n loki svc/loki 3100:3100
curl http://localhost:3100/ready
curl http://localhost:3100/loki/api/v1/labels
```

## Dependencies

- **monitoring**: Grafana datasource configuration
- **storage**: PVC storage for filesystem mode

## References

- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [LogQL Query Language](https://grafana.com/docs/loki/latest/logql/)
