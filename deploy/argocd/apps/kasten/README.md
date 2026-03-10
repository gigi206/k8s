# Kasten K10 — Application-Centric Data Protection

## Overview

Kasten K10 (Veeam Kasten) provides application-centric backup, disaster recovery, and application mobility for Kubernetes. It uses CSI snapshots for volume data and S3 object storage (Rook-Ceph RGW) for backup export.

## Architecture

```
┌──────────────────────────────────────────────────┐
│  Kasten K10 (namespace: kasten-io)               │
│                                                  │
│  gateway ──► dashboardbff ──► catalog-svc         │
│                    │              │               │
│              auth-svc        state-svc            │
│                    │              │               │
│              executor ──► kanister-sidecar         │
│                    │                             │
│              jobs-svc ──► crypto-svc              │
│                                                  │
│  aggregatedapis (K10 API aggregation layer)       │
└──────────────────────────────────────────────────┘
         │                        │
    CSI Snapshots           S3 Export
    (ceph-block)         (Rook-Ceph RGW)
```

## Prerequisites

- `features.backup.enabled: true`
- `features.backup.provider: "kasten"`
- `features.s3.enabled: true` (required for backup export to S3)
- `features.s3.provider: "rook"` (Rook-Ceph ObjectStore)
- Rook-Ceph with CephObjectStore in Ready state
- VolumeSnapshotClass with `k10.kasten.io/is-snapshot-class: "true"` annotation

## Configuration

### Global (`config/config.yaml`)

```yaml
features:
  backup:
    enabled: true
    provider: "kasten"  # or "velero"
  s3:
    enabled: true
    provider: "rook"
```

### Per-environment (`config/dev.yaml` / `config/prod.yaml`)

| Key | Dev | Prod | Description |
|-----|-----|------|-------------|
| `kasten.version` | `8.5.4` | `8.5.4` | Helm chart version (Renovate managed) |
| `kasten.eula.company` | `k8s-dev` | `k8s-prod` | EULA company name |
| `kasten.eula.email` | `admin@k8s.local` | `admin@k8s.local` | EULA email |
| `kasten.resources.requests.cpu` | `50m` | `200m` | CPU request |
| `kasten.resources.requests.memory` | `128Mi` | `512Mi` | Memory request |
| `kasten.persistence.storageClass` | `ceph-block` | `ceph-block` | StorageClass for catalog |
| `kasten.persistence.catalogSize` | `20Gi` | `50Gi` | Catalog PVC size |
| `syncPolicy.automated.enabled` | `true` | `false` | Auto-sync (dev only) |

## S3 Storage (OBC-based)

S3 storage is provisioned in two phases:

**PreSync Job** (`kasten-s3-credentials.yaml`):
1. Creates an `ObjectBucketClaim` (`kasten-storage`) in `kasten-io` namespace
2. Waits for Rook-Ceph to provision the bucket (Secret + ConfigMap)
3. Creates a Secret (`kasten-s3-credentials`) with AWS access keys

**PostSync Job** (`kasten-s3-profile.yaml`):
4. Creates a K10 `Profile` (`ceph-s3`) pointing to the S3 bucket

The Profile is created as PostSync to ensure K10 CRDs are available (installed during the main sync by the Helm chart). The Profile is visible in K10 Dashboard under **Settings > Location Profiles**.

## Authentication

### Token Auth (default)

Always enabled. Generate a token:

```bash
# Create a ServiceAccount token for K10 dashboard access
kubectl -n kasten-io create token k10-k10 --duration=24h
```

### OIDC / Keycloak (conditional)

Enabled when `features.sso.enabled: true` and `features.sso.provider: "keycloak"`.
Requires a Keycloak client `kasten` in the `k8s` realm.

## Dashboard Access

### Via Gateway API (HTTPRoute)

When `features.gatewayAPI.httpRoute.enabled: true`:
- URL: `https://kasten.<common.domain>/k10/`

### Via Port-Forward (dev)

```bash
kubectl -n kasten-io port-forward svc/gateway 8080:8000
# Open http://localhost:8080/k10/
```

## Backup Operations

All backup operations (policies, snapshots, exports, restores) are managed through the K10 Dashboard UI or CLI. Key concepts:

- **Policy**: defines what to backup, when, and where to export
- **Location Profile**: S3 destination for backup export (auto-created by PostSync Job)
- **Snapshot**: CSI volume snapshot (local, fast)
- **Export**: backup data moved to S3 (durable, off-cluster)
- **Restore**: recover from snapshot or export

### Immutable Backups

For immutable backup support, create a dedicated S3 bucket with Object Lock enabled via Rook-Ceph RGW API, then create a K10 Profile with `protectionPeriod` set. See [Kasten docs](https://docs.kasten.io/latest/usage/protect.html#immutable-backups).

## Network Policies

- **Cilium**: `cilium-ingress-policy.yaml` — allows internal traffic + Prometheus scrape
- **Calico**: `calico-ingress-policy.yaml` — equivalent Calico NetworkPolicy

## Monitoring

When `features.monitoring.enabled: true`:
- ServiceMonitor for K10 metrics (port 8000)
- K10 has built-in Prometheus metrics at `/metrics`

## Troubleshooting

### App not syncing
```bash
kubectl get applicationset kasten -n argo-cd -o yaml
# Force refresh
kubectl annotate application kasten -n argo-cd argocd.argoproj.io/refresh=hard
```

### OBC not provisioned
```bash
kubectl -n kasten-io get obc kasten-storage
kubectl -n rook-ceph get cephobjectstore
```

### K10 Profile not created
The Profile is created by a PostSync Job. Check if the Job ran and its logs:
```bash
kubectl -n kasten-io get profiles
kubectl -n kasten-io get jobs kasten-s3-profile -o yaml
kubectl -n kasten-io logs job/kasten-s3-profile
```

### Dashboard access issues
```bash
kubectl -n kasten-io get pods
kubectl -n kasten-io logs -l component=gateway
kubectl -n kasten-io logs -l component=dashboardbff
```
