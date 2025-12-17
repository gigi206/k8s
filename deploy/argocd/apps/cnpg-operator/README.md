# CloudNativePG Operator

CloudNativePG is the Kubernetes operator for managing PostgreSQL databases natively in Kubernetes.

## Overview

- **Wave**: 65
- **Namespace**: `cnpg-system`
- **Helm Chart**: [cloudnative-pg/cloudnative-pg](https://cloudnative-pg.github.io/charts)

## Features

- Automated PostgreSQL cluster provisioning
- High availability with automatic failover
- Rolling updates and minor version upgrades
- Backup and restore (via Barman)
- Connection pooling (PgBouncer)
- Monitoring integration (Prometheus)

## Usage

### Creating a PostgreSQL Cluster

After deploying the operator, create clusters using the `Cluster` CRD:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-cluster
  namespace: my-namespace
spec:
  instances: 3
  storage:
    size: 10Gi
```

### Image Catalog

The ApplicationSet deploys a `ClusterImageCatalog` providing pre-configured PostgreSQL images:
- PostgreSQL 14, 15, 16 (Debian-based)

## Dependencies

- **storage**: Requires a default StorageClass (longhorn or rook)

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [CloudNativePG Helm Chart](https://github.com/cloudnative-pg/charts)
