# Longhorn - Distributed Block Storage

Longhorn est un système de stockage distribué pour Kubernetes qui fournit des volumes persistants répliqués.

## Dépendances

### Automatiques (via ApplicationSets)
Ces composants sont déployés automatiquement dans le bon ordre grâce aux sync waves:

- **CSI External Snapshotter** (Wave 55): Requis pour les snapshots de volumes
  - Déployé automatiquement avant Longhorn
  - ApplicationSet: `csi-external-snapshotter`

- **Prometheus Stack** (Wave 75): Pour le monitoring Longhorn
  - ServiceMonitor et PrometheusRule déployés si `features.monitoring.enabled: true`
  - Alertes automatiques pour l'utilisation disque > 90%

### Manuelles (sur les nodes)

#### iSCSI (Obligatoire)
Longhorn nécessite iSCSI sur **tous les nodes** du cluster:

```bash
# Sur chaque node
apt install -y open-iscsi
systemctl enable --now iscsid.service
```

**Sans iSCSI, Longhorn ne pourra pas attacher les volumes!**

## Configuration

### Environnements

**Dev (`config-dev.yaml`):**
- 1 replica pour les données (pas de HA)
- 1 replica CSI components
- 1 replica Longhorn UI
- Auto-sync activé

**Prod (`config-prod.yaml`):**
- 3 replicas pour les données (HA)
- 3 replicas CSI components (HA)
- 2 replicas Longhorn UI (HA)
- Auto-sync désactivé (manual)
- Backup NFS à configurer

### Ingress UI

L'interface Longhorn est accessible via ingress:
- **Hostname**: `longhorn.{{ .common.domain }}` (ex: `longhorn.gigix`)
- **TLS**: Automatique avec cert-manager
- **ClusterIssuer**: Configuré via `common.clusterIssuer`

Exemple:
```bash
# Dev
https://longhorn.example.local
```

### Snapshots

VolumeSnapshotClass est automatiquement configurée:
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot-vsc
driver: driver.longhorn.io
deletionPolicy: Delete
```

Pour créer un snapshot:
```bash
kubectl create -f - <<EOF
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

### Backup (Prod)

Pour activer les backups NFS, décommenter dans `config-prod.yaml`:
```yaml
longhorn:
  defaultSettings:
    backupTarget: "nfs://backup.example.com:/longhorn-backups"
```

## Monitoring

### Prometheus

Si `features.monitoring.enabled: true`, les ressources suivantes sont déployées:

**ServiceMonitor:**
- Collecte les métriques Longhorn depuis `longhorn-manager`

**PrometheusRule (Alertes):**
- `LonghornVolumeUsageCritical`: Volume > 90% utilisé
- `LonghornNodeUsageCritical`: Node storage > 90%
- `LonghornDiskUsageCritical`: Disk > 90% utilisé

### Grafana Dashboard

Le dashboard Grafana est **automatiquement déployé** via ConfigMap avec le label `grafana_dashboard: "1"`.

**Dashboard**: Longhorn Monitoring (ID 16888, révision 11)
- **Sections**: Volumes, Nodes, Disks, CPU & Memory, Alerts
- **Source**: https://grafana.com/grafana/dashboards/16888-longhorn/
- **Mis à jour**: 2025-11-12
- **Compatible**: Longhorn v1.10.0

Le dashboard sera automatiquement importé dans Grafana au prochain redémarrage ou sync.

## Vérification

### Vérifier le déploiement

```bash
# Pods Longhorn
kubectl get pods -n longhorn-system

# StorageClass par défaut
kubectl get storageclass

# Volumes
kubectl get pv
```

### Accéder à l'UI

```bash
# Via ingress (si configuré)
https://longhorn.example.local

# Ou via port-forward
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Puis: http://localhost:8080
```

### Tester un volume

```bash
# Créer un PVC de test
kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF

# Vérifier
kubectl get pvc longhorn-test-pvc
kubectl get pv
```

## Troubleshooting

### Pods en Pending

**Problème**: Pods ne démarrent pas, status `Pending`

**Cause**: iSCSI non installé/démarré sur les nodes

**Solution**:
```bash
# Sur chaque node
apt install -y open-iscsi
systemctl enable --now iscsid.service
systemctl status iscsid
```

### Volume non attaché

**Problème**: Volume ne s'attache pas au pod

**Vérifications**:
```bash
# Logs Longhorn manager
kubectl logs -n longhorn-system deployment/longhorn-manager

# Events
kubectl get events -n longhorn-system --sort-by='.lastTimestamp'

# Status iSCSI sur le node
ssh node1 "systemctl status iscsid"
```

### Monitoring manquant

**Problème**: Pas de métriques Prometheus

**Vérifications**:
```bash
# ServiceMonitor créé ?
kubectl get servicemonitor -n longhorn-system

# Prometheus scrape config
kubectl get prometheus -n monitoring -o yaml | grep longhorn

# Feature flag activé ?
# Vérifier: features.monitoring.enabled: true dans config.yaml
```

## Docs

- [Longhorn Documentation](https://longhorn.io/docs/)
- [CSI Snapshot Support](https://longhorn.io/docs/latest/snapshots-and-backups/csi-snapshot-support/)
- [Monitoring Guide](https://longhorn.io/docs/latest/monitoring/)
- [Grafana Dashboard 16888](https://grafana.com/grafana/dashboards/16888-longhorn/)
