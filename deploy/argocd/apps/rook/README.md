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
| Object Store (S3) | Enabled (1 replica) | Enabled (3 replicas) |
| RGW instances | 1 | 2+ |
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

### HTTPS Backend avec APISIX Gateway API

Le Ceph Dashboard utilise SSL/TLS en interne (port 8443). Lorsqu'on expose le dashboard via APISIX Gateway API (HTTPRoute), APISIX doit savoir qu'il doit se connecter au backend en HTTPS et non HTTP.

#### Problème

Par défaut, APISIX utilise HTTP pour se connecter aux backends. Avec un backend HTTPS comme le dashboard Ceph, cela provoque une erreur **502 Bad Gateway** car APISIX envoie du HTTP vers un serveur qui attend du HTTPS.

#### Solutions possibles

| Solution | Statut | Description |
|----------|--------|-------------|
| `BackendTrafficPolicy` | ❌ Non fonctionnel | CRD APISIX avec `scheme: https`. L'Ingress Controller réconcilie l'upstream depuis le Service qui n'a pas `appProtocol`, donc réécrit le scheme en HTTP. |
| `ApisixUpstream` | ❌ Incompatible | CRD APISIX natif, mais ne fonctionne qu'avec `ApisixRoute`, pas avec `HTTPRoute` (Gateway API). |
| Désactiver SSL dashboard | ❌ Non recommandé | Connexion non chiffrée entre APISIX et le dashboard. Problèmes avec SAML2 SSO qui nécessite HTTPS. |
| CronJob patch Admin API | ⚠️ Workaround | Patch périodique de l'upstream via l'API Admin APISIX. Fonctionnel mais l'Ingress Controller réécrit la config à chaque réconciliation. |
| **Service avec `appProtocol`** | ✅ **Solution retenue** | Créer un Service personnalisé avec `appProtocol: https`. APISIX détecte automatiquement le scheme depuis ce champ. |

#### Solution implémentée

Rook operator crée et gère le Service `rook-ceph-mgr-dashboard` mais ne permet pas de configurer le champ `appProtocol` (pas de support dans le CRD CephCluster).

Notre solution : créer un **Service personnalisé** `ceph-dashboard-https` avec :
- Le même sélecteur de pods que le Service de Rook
- Le champ `appProtocol: https` pour la détection automatique

```yaml
# kustomize/httproute/dashboard-service-https.yaml
apiVersion: v1
kind: Service
metadata:
  name: ceph-dashboard-https
  namespace: rook-ceph
spec:
  type: ClusterIP
  selector:
    app: rook-ceph-mgr
    mgr_role: active
    rook_cluster: rook-ceph
  ports:
    - name: https-dashboard
      port: 8443
      targetPort: 8443
      protocol: TCP
      appProtocol: https    # <- Clé de la solution
```

L'HTTPRoute pointe vers ce Service au lieu de `rook-ceph-mgr-dashboard` :

```yaml
# kustomize/httproute/httproute.yaml
backendRefs:
  - name: ceph-dashboard-https  # Notre Service personnalisé
    port: 8443
```

#### Pourquoi Rook ne supporte pas appProtocol ?

Analyse du code source Rook (`pkg/operator/ceph/cluster/mgr/spec.go`) :

```go
func (c *Cluster) makeDashboardService(name string) (*v1.Service, error) {
    // ...
    Ports: []v1.ServicePort{
        {
            Name:       portName,
            Port:       int32(c.dashboardPublicPort()),
            TargetPort: intstr.IntOrString{IntVal: int32(c.dashboardInternalPort())},
            Protocol:   v1.ProtocolTCP,
            // Pas de champ appProtocol !
        },
    },
}
```

Le CRD `CephCluster` (`DashboardSpec`) ne propose aucune option pour personnaliser les annotations ou champs du Service dashboard. Une feature request pourrait être soumise au projet Rook pour ajouter cette fonctionnalité.

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

### S3 Endpoint

| Type | URL |
|------|-----|
| Internal (cluster) | `http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80` |
| External (HTTPRoute) | `https://s3.<domain>` (e.g., `https://s3.k8s.lan`) |

> External access requires `features.gatewayAPI.httpRoute.enabled: true` in global config.

### Create a Bucket

When you create an `ObjectBucketClaim`, Rook automatically provisions:
- The S3 bucket in Ceph
- A **Secret** with S3 credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
- A **ConfigMap** with bucket info (`BUCKET_HOST`, `BUCKET_PORT`, `BUCKET_NAME`)

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

### Using S3 in Your Application

Reference the auto-created Secret and ConfigMap in your Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: s3-app
  namespace: my-app
spec:
  containers:
  - name: app
    image: my-app:latest
    env:
    # S3 Credentials (from Secret)
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: my-bucket
          key: AWS_ACCESS_KEY_ID
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: my-bucket
          key: AWS_SECRET_ACCESS_KEY
    # Bucket configuration (from ConfigMap)
    - name: S3_ENDPOINT
      value: "http://$(BUCKET_HOST):$(BUCKET_PORT)"
    - name: BUCKET_HOST
      valueFrom:
        configMapKeyRef:
          name: my-bucket
          key: BUCKET_HOST
    - name: BUCKET_PORT
      valueFrom:
        configMapKeyRef:
          name: my-bucket
          key: BUCKET_PORT
    - name: BUCKET_NAME
      valueFrom:
        configMapKeyRef:
          name: my-bucket
          key: BUCKET_NAME
```

### Get S3 Credentials Manually

```bash
# Access Key
kubectl -n my-app get secret my-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d

# Secret Key
kubectl -n my-app get secret my-bucket -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d

# Bucket info
kubectl -n my-app get configmap my-bucket -o jsonpath='{.data}'
```

### Test S3 with AWS CLI

```bash
# Set credentials
export AWS_ACCESS_KEY_ID=$(kubectl -n my-app get secret my-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl -n my-app get secret my-bucket -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
export BUCKET_NAME=$(kubectl -n my-app get configmap my-bucket -o jsonpath='{.data.BUCKET_NAME}')

# Option 1: External access via HTTPRoute (recommended)
aws --endpoint-url https://s3.k8s.lan --no-verify-ssl s3 ls s3://$BUCKET_NAME/
aws --endpoint-url https://s3.k8s.lan --no-verify-ssl s3 cp myfile.txt s3://$BUCKET_NAME/

# Option 2: Port-forward (if no HTTPRoute)
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-ceph-objectstore 8080:80 &
aws --endpoint-url http://localhost:8080 s3 ls s3://$BUCKET_NAME/
aws --endpoint-url http://localhost:8080 s3 cp myfile.txt s3://$BUCKET_NAME/
```

### Check Object Store Status

```bash
# Status
kubectl get cephobjectstore -n rook-ceph

# List buckets
kubectl get objectbucketclaim -A
```

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
