# CSI External Snapshotter - Volume Snapshot CRDs

CSI External Snapshotter fournit les CustomResourceDefinitions (CRDs) pour les snapshots de volumes Kubernetes. Il permet aux CSI drivers (comme Longhorn) de créer, gérer et restaurer des snapshots de volumes.

## Vue d'Ensemble

**Deployment**: CRDs uniquement (pas de pods)
**Wave**: 55 (avant Longhorn qui dépend de ces CRDs)
**Source**: Git repository (CRDs YAML)
**Namespace**: cluster-wide (CRDs sont globaux)

## Dépendances

### Requises
- **Kubernetes 1.20+**: Support natif des VolumeSnapshot

### Optionnelles
- **Longhorn** (Wave 60): CSI driver qui utilise ces CRDs pour les snapshots
- **Autres CSI drivers**: Tout driver supportant les snapshots (AWS EBS, GCP PD, etc.)

## CRDs Installées

### VolumeSnapshot

Représente une snapshot d'un PersistentVolumeClaim (PVC).

**Exemple**:
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: longhorn-snapshot-vsc
  source:
    persistentVolumeClaimName: my-pvc
```

### VolumeSnapshotClass

Définit comment créer les snapshots (similaire à StorageClass pour PV).

**Exemple**:
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot-vsc
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
```

### VolumeSnapshotContent

Représente le contenu réel du snapshot (similaire à PersistentVolume pour PVC).

**Créé automatiquement** par le CSI driver lors de la création d'un VolumeSnapshot.

## Usage

### Créer un Snapshot

```bash
# 1. Vérifier que la VolumeSnapshotClass existe
kubectl get volumesnapshotclass

# 2. Créer un VolumeSnapshot
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-pvc-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: longhorn-snapshot-vsc
  source:
    persistentVolumeClaimName: my-pvc
EOF

# 3. Vérifier le snapshot
kubectl get volumesnapshot -n default
kubectl describe volumesnapshot my-pvc-snapshot -n default
```

### Restaurer depuis un Snapshot

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc-restored
  namespace: default
spec:
  storageClassName: longhorn
  dataSource:
    name: my-pvc-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

### Lister les Snapshots

```bash
# Tous les namespaces
kubectl get volumesnapshot --all-namespaces

# Namespace spécifique
kubectl get volumesnapshot -n default

# Détails
kubectl describe volumesnapshot my-pvc-snapshot -n default

# Snapshot content
kubectl get volumesnapshotcontent
```

### Supprimer un Snapshot

```bash
# Supprimer le VolumeSnapshot
kubectl delete volumesnapshot my-pvc-snapshot -n default

# Le VolumeSnapshotContent est supprimé automatiquement (si deletionPolicy=Delete)
```

## Integration avec Longhorn

Les CRDs CSI External Snapshotter sont **requises** par Longhorn pour les fonctionnalités de snapshot.

### VolumeSnapshotClass Longhorn

Longhorn crée automatiquement une VolumeSnapshotClass:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot-vsc
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
```

### Snapshot Manuel (Longhorn UI)

**Via Longhorn UI**:
1. Accéder à Longhorn UI: https://longhorn.k8s.lan
2. Aller dans "Volume"
3. Sélectionner le volume
4. Cliquer "Take Snapshot"
5. Le snapshot apparaît dans "Snapshot"

**Via kubectl**:
```bash
# Créer un snapshot
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-volume-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: longhorn-snapshot-vsc
  source:
    persistentVolumeClaimName: my-pvc
EOF
```

### Backup vs Snapshot

**Snapshot** (CSI External Snapshotter):
- Stocké sur le même cluster/storage
- Rapide à créer et restaurer
- Pas de protection contre la perte du cluster

**Backup** (Longhorn native):
- Stocké sur backend externe (S3, NFS)
- Protection contre la perte du cluster
- Plus lent à créer et restaurer

**Recommandation**: Utiliser les deux!
- **Snapshots**: Pour rollback rapide (bad deployment)
- **Backups**: Pour disaster recovery (cluster perdu)

## Troubleshooting

### CRDs non installées

**Symptôme**: `error: the server doesn't have a resource type "volumesnapshot"`

**Vérifier**:
```bash
# Vérifier les CRDs
kubectl get crd | grep snapshot

# Devrait afficher:
# volumesnapshotclasses.snapshot.storage.k8s.io
# volumesnapshotcontents.snapshot.storage.k8s.io
# volumesnapshots.snapshot.storage.k8s.io
```

**Solution**:
```bash
# Vérifier que l'ApplicationSet est déployé
kubectl get application -n argo-cd csi-external-snapshotter

# Synchroniser si nécessaire
argocd app sync csi-external-snapshotter
```

### VolumeSnapshot reste en "Pending"

**Symptôme**: VolumeSnapshot ne devient jamais "ReadyToUse"

**Vérifications**:
```bash
# Détails du snapshot
kubectl describe volumesnapshot my-snapshot -n default

# Events
kubectl get events -n default | grep snapshot

# Vérifier le CSI driver (Longhorn)
kubectl get pods -n longhorn-system
kubectl logs -n longhorn-system deployment/csi-snapshotter
```

**Causes courantes**:
- **VolumeSnapshotClass inexistante**: Créer la classe
- **CSI driver pas déployé**: Installer Longhorn
- **PVC source inexistante**: Vérifier que le PVC existe
- **Quota dépassé**: Vérifier l'espace disponible

### Restauration échoue

**Symptôme**: PVC restore reste en "Pending"

**Vérifications**:
```bash
# PVC status
kubectl describe pvc my-pvc-restored -n default

# VolumeSnapshot existe et est ReadyToUse?
kubectl get volumesnapshot my-snapshot -n default

# StorageClass configurée?
kubectl get storageclass
```

**Causes courantes**:
- **Snapshot pas ReadyToUse**: Attendre que le snapshot soit prêt
- **StorageClass différente**: Utiliser la même StorageClass que l'original
- **Quota dépassé**: Vérifier l'espace disponible

## Configuration

Aucune configuration nécessaire. Les CRDs sont simplement déployées.

### Dev et Prod

Configuration identique:
```yaml
# config-dev.yaml et config-prod.yaml
environment: dev  # ou prod
appName: csi-external-snapshotter

syncPolicy:
  automated:
    enabled: true
    prune: true
    selfHeal: true
```

## Monitoring

Aucun monitoring spécifique pour les CRDs. Le monitoring des snapshots se fait via:
- **Longhorn UI**: Voir les snapshots et leur statut
- **Longhorn metrics**: Alertes sur échecs de snapshot (voir longhorn/README.md)

## Docs

- [Kubernetes CSI Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [CSI External Snapshotter](https://github.com/kubernetes-csi/external-snapshotter)
- [Longhorn Snapshots](https://longhorn.io/docs/latest/snapshots-and-backups/snapshot/)
- [VolumeSnapshot API Reference](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume-snapshot-v1/)
