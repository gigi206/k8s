# Rook-Ceph

Rook-Ceph provides distributed block and file storage for Kubernetes using Ceph.

## Overview

This ApplicationSet deploys:
- **rook-ceph operator**: Manages Ceph cluster lifecycle
- **rook-ceph-cluster**: Creates the actual Ceph cluster with storage pools

## Prerequisites

- Raw block device available on worker nodes (`/dev/vdb` by default)
- Minimum 1 OSD node (3+ recommended for production)

## Storage Classes Created

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `ceph-block` | RBD | Yes | Block storage (ReadWriteOnce) |
| `ceph-filesystem` | CephFS | No | Shared filesystem (ReadWriteMany) - prod only |
| `ceph-bucket` | RGW | No | S3-compatible object storage - when objectStore.enabled |

## Configuration

### Enable Rook as Storage Provider

In `deploy/argocd/config/config.yaml`:

```yaml
features:
  storage:
    enabled: true
    provider: "rook"      # Change from "longhorn"
    class: "ceph-block"   # StorageClass for PVCs
```

### Environment Differences

| Setting | Dev | Prod |
|---------|-----|------|
| MON count | 1 | 3 |
| MGR count | 1 | 2 |
| OSD replicas | 1 | 3 |
| CephFS | Disabled | Enabled |
| Object Store (S3) | Disabled | Enabled |
| allowMultiplePerNode | true | false |

### OSD Device Configuration

By default, Rook uses `/dev/vdb` for OSDs. To change:

```yaml
# config/dev.yaml or prod.yaml
rook:
  storage:
    deviceFilter: "^vdb$"  # Regex pattern for device names
```

## Ceph Dashboard

Access the Ceph Dashboard via HTTPRoute:
- URL: `https://ceph.<domain>` (e.g., `https://ceph.k8s.lan`)

### Get Dashboard Password

```bash
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d
```

Default username: `admin`

### SSO / Authentification

#### SAML2 (actuel)

Le dashboard utilise SAML2 avec Keycloak pour l'authentification SSO. Configuré automatiquement si `features.sso.enabled: true` dans la config globale.

Fonctionnement :
1. L'utilisateur accède à `https://ceph.<domain>`
2. Redirection vers Keycloak pour authentification
3. Retour au dashboard avec session SSO

#### OIDC (futur)

> **Note** : L'OIDC natif du dashboard Ceph nécessite :
> - **Ceph 20.x (Tentacle)** minimum
> - Services `mgmt-gateway` et `oauth2-proxy` intégrés à Ceph
> - Support Rook à venir (probablement Rook 1.19+)
>
> Actuellement Rook 1.18.x supporte uniquement Ceph 19.x (Squid), donc SAML2 est utilisé.

## Object Store (S3)

When `objectStore.enabled: true`, a RADOS Gateway (RGW) is deployed providing S3-compatible storage.

### Configuration

```yaml
# config/dev.yaml or prod.yaml
rook:
  objectStore:
    enabled: true
    replicaSize: 3       # Data replication
    gateway:
      instances: 2       # RGW instances for HA
```

### Create a Bucket

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: my-bucket
  namespace: my-app
spec:
  generateBucketName: my-bucket
  storageClassName: ceph-bucket
```

### Get S3 Credentials

```bash
# After ObjectBucketClaim is created
kubectl -n my-app get secret my-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
kubectl -n my-app get secret my-bucket -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d
```

### S3 Endpoint

Internal: `http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80`

## Monitoring

### Prometheus Alerts

| Alert | Severity | Description |
|-------|----------|-------------|
| CephHealthCritical | critical | Cluster HEALTH_ERR |
| CephHealthWarning | warning | Cluster HEALTH_WARN |
| CephClusterDown | critical | No metrics collected |
| CephOSDDown | critical | OSD is down |
| CephOSDNearlyFull | warning | OSD >80% full |
| CephOSDFull | critical | OSD >90% full |
| CephMonQuorumLost | critical | Monitor lost quorum |
| CephPoolNearlyFull | warning | Pool >80% full |
| CephPGsDegraded | warning | PGs in degraded state |
| CephPGsStuckUnclean | critical | PGs stuck undersized |
| CephSlowOps | warning | Slow operations detected |

### Grafana Dashboard

A basic Ceph Cluster dashboard is included with:
- Cluster health status
- OSDs up/down count
- MONs in quorum
- Capacity usage
- Throughput and IOPS
- Placement Groups status

## Troubleshooting

### Check Ceph Status

```bash
# Get Ceph cluster status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# List OSDs
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Check pool status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd pool ls detail
```

### OSD Not Created

1. Verify the device exists:
   ```bash
   lsblk | grep vdb
   ```

2. Check if device has partitions (must be raw):
   ```bash
   wipefs -a /dev/vdb  # Warning: destroys all data!
   ```

3. Check operator logs:
   ```bash
   kubectl -n rook-ceph logs -l app=rook-ceph-operator
   ```

### Cluster Health Warning

```bash
# Get detailed health info
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
```

## References

- [Rook Documentation](https://rook.io/docs/rook/latest/)
- [Ceph Cluster Helm Chart](https://rook.io/docs/rook/latest-release/Helm-Charts/ceph-cluster-chart/)
- [Ceph Dashboard](https://docs.ceph.com/en/latest/mgr/dashboard/)
