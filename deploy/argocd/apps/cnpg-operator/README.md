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

## Configuration

### Dev (config/dev.yaml)

```yaml
cnpgOperator:
  version: "0.25.0"
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

### Prod (config/prod.yaml)

```yaml
cnpgOperator:
  version: "0.25.0"
  replicas: 2  # HA
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

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

### Cluster with HA and Backup

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-cluster
  namespace: my-namespace
spec:
  instances: 3

  # Image from ClusterImageCatalog
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ClusterImageCatalog
    name: postgresql
    major: 16

  storage:
    size: 10Gi
    storageClass: longhorn

  # Backup configuration (requires S3/MinIO)
  backup:
    barmanObjectStore:
      destinationPath: s3://backups/my-cluster
      endpointURL: http://minio.minio.svc:9000
      s3Credentials:
        accessKeyId:
          name: backup-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: backup-creds
          key: SECRET_ACCESS_KEY
    retentionPolicy: "30d"
```

### Image Catalog

The ApplicationSet deploys a `ClusterImageCatalog` providing pre-configured PostgreSQL images:
- PostgreSQL 14, 15, 16 (Debian-based)

Reference in Cluster spec:
```yaml
imageCatalogRef:
  apiGroup: postgresql.cnpg.io
  kind: ClusterImageCatalog
  name: postgresql
  major: 16  # or 15, 14
```

## Monitoring

### Prometheus Alerts

12 alertes sont configurées pour l'opérateur et les clusters gérés :

**Opérateur (cnpg-system)**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| CNPGOperatorDown | critical | Opérateur indisponible (5m) |
| CNPGOperatorPodNotReady | critical | Pod opérateur non ready (5m) |
| CNPGOperatorPodRestarting | high | Pod en restart loop (10m) |

**Clusters PostgreSQL gérés**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| CNPGInstanceFenced | critical | Instance PostgreSQL isolée |
| CNPGNoHighAvailability | high | Cluster sans HA (single node) |
| CNPGHighReplicationLag | high | Lag réplication > 30s |
| CNPGCriticalReplicationLag | critical | Lag réplication > 120s |
| CNPGNoStreamingReplicas | warning | Primary sans réplicas |
| CNPGWALArchiveFailing | high | Échec archivage WAL |
| CNPGWALAccumulating | warning | WAL segments > 100 |
| CNPGManualSwitchoverRequired | critical | Switchover manuel requis |
| CNPGCollectionErrors | high | Erreurs collecte métriques |

### Métriques Prometheus

Principales métriques exposées par les instances PostgreSQL :

```promql
# État du cluster
cnpg_collector_up                         # Collecteur actif
cnpg_collector_fencing_on                 # Instance isolée
cnpg_collector_manual_switchover_required # Switchover requis

# Réplication
cnpg_pg_replication_lag                   # Lag en secondes
cnpg_pg_replication_streaming_replicas    # Nombre de réplicas
cnpg_pg_replication_in_recovery           # Instance en recovery

# WAL et archivage
cnpg_collector_pg_wal{value="count"}      # Nombre de segments WAL
cnpg_pg_stat_archiver_failed_count        # Échecs d'archivage

# Connexions
cnpg_pg_stat_activity_count               # Connexions actives
```

## Troubleshooting

### Operator not starting

```bash
# Vérifier les pods
kubectl get pods -n cnpg-system

# Logs de l'opérateur
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg

# Events
kubectl get events -n cnpg-system --sort-by='.lastTimestamp'
```

### Cluster not becoming ready

```bash
# Status du cluster
kubectl get cluster -n my-namespace my-cluster

# Description détaillée
kubectl describe cluster -n my-namespace my-cluster

# Logs des pods PostgreSQL
kubectl logs -n my-namespace my-cluster-1

# Vérifier le failover manager
kubectl logs -n my-namespace my-cluster-1 -c postgres
```

### Replication lag issues

```bash
# Vérifier le lag
kubectl exec -n my-namespace my-cluster-1 -- psql -c "SELECT * FROM pg_stat_replication;"

# Vérifier les WAL
kubectl exec -n my-namespace my-cluster-1 -- psql -c "SELECT * FROM pg_stat_archiver;"

# Forcer un checkpoint
kubectl exec -n my-namespace my-cluster-1 -- psql -c "CHECKPOINT;"
```

### Backup failures

```bash
# Lister les backups
kubectl get backup -n my-namespace

# Status d'un backup
kubectl describe backup -n my-namespace my-backup

# Logs du pod de backup
kubectl logs -n my-namespace -l cnpg.io/jobRole=backup
```

### Connection issues

```bash
# Vérifier les secrets de connexion
kubectl get secret -n my-namespace my-cluster-app -o yaml

# Tester la connexion
kubectl run -it --rm --restart=Never pg-client \
  --image=postgres:16 \
  --env="PGPASSWORD=$(kubectl get secret -n my-namespace my-cluster-app -o jsonpath='{.data.password}' | base64 -d)" \
  -- psql -h my-cluster-rw.my-namespace.svc -U app -d app -c "SELECT version();"
```

## Dependencies

- **storage**: Requires a default StorageClass (longhorn or rook)
- **monitoring**: Prometheus Operator for metrics collection

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [CloudNativePG Helm Chart](https://github.com/cloudnative-pg/charts)
- [Cluster CRD Reference](https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/)
- [Backup and Recovery](https://cloudnative-pg.io/documentation/current/backup_recovery/)
