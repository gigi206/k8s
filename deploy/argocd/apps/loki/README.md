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

## Dependencies

- **monitoring**: Grafana datasource configuration
- **storage**: PVC storage for filesystem mode

## References

- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [LogQL Query Language](https://grafana.com/docs/loki/latest/logql/)
