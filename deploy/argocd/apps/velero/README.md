# Velero - Kubernetes Backup & Restore

## Overview

Velero provides backup and restore capabilities for Kubernetes cluster resources and persistent volumes. It uses CSI snapshots (Ceph RBD) for persistent volume backups, with snapshot data moved to S3-compatible object storage (Rook-Ceph RGW) for durability.

## Architecture

```
Velero Server (Deployment)
  |-- BackupStorageLocation (S3 via Rook-Ceph RGW)
  |-- VolumeSnapshotClass (Ceph RBD CSI)
  |-- Node-Agent DaemonSet (data mover: snapshot → S3)
  |-- Backup Schedules (configurable cron)
  |
  ObjectBucketClaim --> Rook-Ceph ObjectStore
  PreSync Job --> Credentials Secret + BSL CR
```

### Backup Strategy: CSI Snapshots + Data Movement

Velero uses **CSI VolumeSnapshots** with **data movement to S3** for persistent volume backups.

**Current configuration**: CSI Snapshots + Data Movement (mode 3 ci-dessous).

### Volume Backup Modes

Velero propose 3 modes de sauvegarde des volumes persistants. Chaque mode a un impact différent sur ce qui est sauvegardé, les composants requis, et les garanties de restauration.

#### Mode 1 : CSI Snapshots only (`snapshotMoveData: false`, `nodeAgent: false`)

```
PVC ──CSI driver──> RBD Snapshot (local Ceph)
K8s manifests ────> S3 (metadata only)
```

| Aspect                    | Valeur                                                                                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Ce qui va en S3**       | Uniquement les manifests K8s (Deployments, Services, ConfigMaps, Secrets, etc.) et les **references** aux VolumeSnapshots |
| **Données des volumes**   | Restent en tant que snapshots RBD **locaux** sur le cluster Ceph                                                          |
| **Composants requis**     | Velero server, VolumeSnapshotClass, CSI driver                                                                            |
| **Node-agent**            | Non requis                                                                                                                |
| **Vitesse de backup**     | Rapide (snapshot COW instantane)                                                                                          |
| **Coherence**             | Point-in-time consistency (snapshot atomique)                                                                             |
| **Restore si Ceph OK**    | Complet (manifests depuis S3 + volumes depuis RBD snapshots)                                                              |
| **Restore si Ceph perdu** | Manifests K8s uniquement, **donnees volumes perdues**                                                                     |
| **Cas d'usage**           | Rollback rapide apres mauvais deploiement, protection contre suppression accidentelle                                     |

#### Mode 2 : File-System Backup / FSB (`defaultVolumesToFsBackup: true`, `nodeAgent: true`)

```
PVC ──node-agent──> lecture fichiers ──Kopia──> S3
K8s manifests ──────────────────────────────> S3
```

| Aspect                    | Valeur                                                                            |
| ------------------------- | --------------------------------------------------------------------------------- |
| **Ce qui va en S3**       | Manifests K8s + **donnees completes des volumes** (fichier par fichier via Kopia) |
| **Donnees des volumes**   | Copies integralement en S3 par le node-agent                                      |
| **Composants requis**     | Velero server, node-agent DaemonSet (tourne en root)                              |
| **VolumeSnapshotClass**   | Non requise                                                                       |
| **Vitesse de backup**     | Lent (lecture sequentielle de tous les fichiers du PV)                            |
| **Impact cluster**        | Charge I/O significative sur les noeuds pendant le backup                         |
| **Coherence**             | **Aucune** (pas de point-in-time consistency, voir avertissement ci-dessous)      |
| **Restore si Ceph perdu** | **Complet** (tout est en S3)                                                      |
| **Cas d'usage**           | Volumes non-CSI, drivers sans support snapshot, DR complete                       |

> **Avertissement** : le FSB lit les fichiers sequentiellement pendant que l'application continue d'ecrire sur le volume. Le backup peut contenir un etat **qui n'a jamais existe** a un instant donne (fichier A lu a T1, fichier B lu a T2, mais l'application a modifie les deux entre-temps). Pour les bases de donnees (PostgreSQL, MySQL), cela peut produire des WAL/binlogs incoherents avec les fichiers data, rendant la restauration impossible ou corrompue. **Privilegier le mode 3 (CSI + Move)** qui garantit un snapshot atomique.

#### Mode 3 : CSI Snapshots + Data Movement (`snapshotMoveData: true`, `nodeAgent: true`) **<-- actif**

```
PVC ──CSI driver──> RBD Snapshot ──node-agent──> S3
K8s manifests ─────────────────────────────────> S3
```

| Aspect                    | Valeur                                                                 |
| ------------------------- | ---------------------------------------------------------------------- |
| **Ce qui va en S3**       | Manifests K8s + **donnees completes des volumes** (depuis le snapshot) |
| **Donnees des volumes**   | Snapshot CSI cree, puis node-agent uploade les donnees en S3           |
| **Composants requis**     | Velero server, node-agent DaemonSet, VolumeSnapshotClass, CSI driver   |
| **Vitesse de backup**     | Snapshot instantane + upload asynchrone en S3                          |
| **Impact cluster**        | Modere (lecture depuis snapshot, pas depuis le PV actif)               |
| **Coherence**             | Point-in-time consistency (snapshot atomique)                          |
| **Restore si Ceph perdu** | **Complet** (tout est en S3)                                           |
| **Cas d'usage**           | DR complete avec coherence point-in-time                               |

### Comparatif rapide

|                               | Mode 1: CSI only          | Mode 2: FSB                      | Mode 3: CSI + Move **<-- actif** |
| ----------------------------- | ------------------------- | -------------------------------- | -------------------------------- |
| **Donnees volumes en S3**     | Non                       | Oui                              | Oui                              |
| **Node-agent requis**         | Non                       | Oui                              | Oui                              |
| **Point-in-time consistency** | Oui                       | Non (fichier par fichier)        | Oui                              |
| **Survit a perte Ceph**       | Non                       | Oui                              | Oui                              |
| **Vitesse backup**            | Instantane                | Lent                             | Snapshot rapide + upload         |
| **Config**                    | `snapshotMoveData: false` | `defaultVolumesToFsBackup: true` | `snapshotMoveData: true`         |

### Deduplication et backups incrementaux

Chaque backup Velero est un **backup logiquement complet** : il est auto-suffisant et restaurable independamment, sans avoir besoin des backups precedents. Il n'y a pas de chaine incrementale (contrairement aux outils classiques full → incr1 → incr2).

La deduplication se fait uniquement au niveau **stockage** par Kopia. Les donnees des volumes sont decoupees en chunks : si un bloc existe deja dans le repo Kopia, il n'est pas re-uploade, mais le backup le **reference**. Cela signifie :

- **Supprimer un ancien backup ne casse pas les suivants** : chaque backup est autonome
- **Pas de choix full vs incremental** : on obtient la fiabilite d'un full (restauration autonome) avec l'efficacite d'un incremental (espace disque)
- **La deduplication est intrinseque a Kopia** et ne peut pas etre desactivee
- **Garbage collection** : les blocs qui ne sont plus references par aucun backup sont nettoyes automatiquement par la maintenance du repo Kopia

**Comportement observe** (cluster dev, 8 PVCs) :

|                                  | Backup 1 (`manual-test-3`) | Backup 2 (`manual-test-4`)          |
| -------------------------------- | -------------------------- | ----------------------------------- |
| **DataUploads**                  | 8 PVCs, ~628 Mo uploades   | 8 PVCs, ~723 Mo traites             |
| **Taille metadata** (`backups/`) | 6.5 Mo                     | 6.4 Mo                              |
| **Taille totale bucket**         | ~341 Mo                    | ~584 Mo (Kopia) + ~13 Mo (metadata) |
| **Espace Kopia supplementaire**  | -                          | ~243 Mo (+71%)                      |
| **Duree**                        | ~5 min                     | ~2 min                              |

Sans deduplication, le 2e backup aurait double la taille du bucket (~1.2 Go). Grace a la deduplication par blocs, seuls les chunks qui ont change entre les deux snapshots sont uploades. Les volumes dont le contenu n'a pas change (ex: ConfigMaps, Secrets montes en PVC) ne consomment quasiment aucun espace supplementaire.

> **Note** : le ratio de deduplication depend du volume de changements entre les backups. Pour des backups schedules toutes les 24h, la majorite des blocs seront identiques et l'espace incremental sera minimal.

**Comportement a la suppression d'un backup** :

Quand on supprime un backup (`velero backup delete`), seules les **metadata** (`backups/<name>/`) sont supprimees immediatement. Les **donnees Kopia** (`kopia/`) sont conservees tant qu'au moins un autre backup les reference :

|                  | Avant suppression (2 backups)       | Apres suppression (1 backup) |
| ---------------- | ----------------------------------- | ---------------------------- |
| **`backups/`**   | `manual-test-3/` + `manual-test-4/` | `manual-test-4/` uniquement  |
| **`kopia/`**     | 7 repos, 571 Mo                     | 7 repos, 571 Mo (inchange)   |
| **Total bucket** | 612 Mo                              | 606 Mo (-6 Mo metadata)      |

Les blocs Kopia orphelins (plus references par aucun backup) sont nettoyes lors de la **maintenance automatique du repo** (garbage collection periodique). La liberation d'espace Kopia n'est donc pas immediate mais differee.

### VolumeSnapshotClasses

Deux `VolumeSnapshotClass` sont deployes pour couvrir deux cas d'usage complementaires :

| VolumeSnapshotClass          | `deletionPolicy` | Label Velero                                 | Usage                                                        |
| ---------------------------- | ---------------- | -------------------------------------------- | ------------------------------------------------------------ |
| `ceph-block-snapshot`        | `Delete`         | `velero.io/csi-volumesnapshot-class: "true"` | Backups Velero schedules (snapshot supprime apres upload S3) |
| `ceph-block-snapshot-retain` | `Retain`         | aucun                                        | Snapshots manuels via `kubectl` (rollback local instantane)  |

**Pourquoi deux classes** : Velero utilise automatiquement la classe avec le label `velero.io/csi-volumesnapshot-class: "true"` (une seule par driver CSI). On ne peut pas choisir la classe par backup. La classe `Delete` evite l'accumulation de snapshots locaux pour les backups automatiques. La classe `Retain` permet de creer des snapshots manuels pour du rollback rapide sans telecharger depuis S3.

#### Snapshot manuel (rollback rapide)

**Creer un snapshot** :

```bash
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: myapp-snap-before-upgrade
  namespace: myapp
spec:
  volumeSnapshotClassName: ceph-block-snapshot-retain
  source:
    persistentVolumeClaimName: myapp-data
EOF

# Verifier le snapshot
kubectl get volumesnapshot -n myapp
```

**Restaurer depuis un snapshot local** :

Un PVC existant bound a un PV ne peut pas etre ecrase. Il faut supprimer le PVC puis le recreer depuis le snapshot :

```bash
# 1. Scale down le workload pour liberer le PVC
kubectl scale deployment myapp -n myapp --replicas=0

# 2. Supprimer le PVC actuel
kubectl delete pvc myapp-data -n myapp

# 3. Recreer le PVC depuis le snapshot (clone instantane Ceph)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  namespace: myapp
spec:
  storageClassName: ceph-block
  dataSource:
    name: myapp-snap-before-upgrade
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

# 4. Scale up le workload
kubectl scale deployment myapp -n myapp --replicas=1

# 5. Nettoyage du snapshot quand il n'est plus necessaire
kubectl delete volumesnapshot myapp-snap-before-upgrade -n myapp
```

> **Note** : le PVC recree porte le meme nom que l'original, le Deployment le retrouve automatiquement au scale up. L'ensemble de la procedure prend quelques secondes (clone COW Ceph, pas de telechargement).

#### Comparaison des methodes de restauration

|                         | Restore Velero (S3)                | Restore snapshot local                  |
| ----------------------- | ---------------------------------- | --------------------------------------- |
| **Vitesse**             | Lent (telechargement reseau)       | Instantane (clone COW Ceph)             |
| **Prerequis**           | Node-agent, connectivite S3        | Ceph fonctionnel, snapshot existant     |
| **Survit a perte Ceph** | Oui                                | Non                                     |
| **Necessite Velero**    | Oui                                | Non (`kubectl` suffit)                  |
| **Granularite**         | Namespace / ressources             | PVC individuel                          |
| **Cas d'usage**         | Disaster recovery, restore complet | Rollback rapide avant upgrade/migration |

> **Attention** : les snapshots `Retain` s'accumulent sur Ceph et consomment de l'espace (COW). Penser a les nettoyer manuellement apres usage (`kubectl delete volumesnapshot`).

### Configuration actuelle

- `defaultSnapshotMoveData: true` : les donnees des snapshots CSI sont uploadees en S3
- `defaultVolumesToFsBackup: false` : pas de FSB (backup fichier par fichier)
- `features: EnableCSI` : active le support CSI integre de Velero
- `VolumeSnapshotClass` `ceph-block-snapshot` avec label Velero : auto-decouverte pour les backups (Delete)
- `VolumeSnapshotClass` `ceph-block-snapshot-retain` sans label : snapshots manuels (Retain)

### Annotations de controle

Velero supporte des annotations pour controler finement ce qui est sauvegarde :

| Annotation                                 | Valeur      | Effet                                                              |
| ------------------------------------------ | ----------- | ------------------------------------------------------------------ |
| `velero.io/exclude-from-backup`            | `"true"`    | Exclut la ressource du backup (sur n'importe quelle ressource K8s) |
| `backup.velero.io/backup-volumes`          | `vol1,vol2` | Sauvegarde **uniquement** ces volumes du pod (opt-in explicite)    |
| `backup.velero.io/backup-volumes-excludes` | `vol1,vol2` | Exclut ces volumes du pod (tous les autres sont sauvegardes)       |

```yaml
# Exclure un PVC du backup
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cache-pvc
  annotations:
    velero.io/exclude-from-backup: "true"

# Exclure un volume temporaire du pod
apiVersion: v1
kind: Pod
metadata:
  name: myapp
  annotations:
    backup.velero.io/backup-volumes-excludes: "tmp-data,cache"
```

### Coherence des backups

Par defaut, les backups Velero sont **crash-consistent** : le snapshot CSI est atomique (equivalent a couper le courant), mais les applications peuvent avoir des donnees en memoire non flush sur disque. Deux approches complementaires pour ameliorer la coherence :

#### Approche 1 : Hooks Velero (quiesce applicatif)

Velero supporte des annotations `pre`/`post` hook sur les pods pour executer des commandes **dans le container** avant et apres le snapshot :

| Annotation                            | Valeur                  | Effet                                     |
| ------------------------------------- | ----------------------- | ----------------------------------------- |
| `pre.hook.backup.velero.io/command`   | `'["/bin/cmd", "arg"]'` | Commande executee avant le backup du pod  |
| `pre.hook.backup.velero.io/container` | `container-name`        | Container cible (defaut : premier du pod) |
| `pre.hook.backup.velero.io/on-error`  | `Fail` ou `Continue`    | Comportement si la commande echoue        |
| `pre.hook.backup.velero.io/timeout`   | `30s`                   | Timeout de la commande                    |
| `post.hook.backup.velero.io/command`  | `'["/bin/cmd", "arg"]'` | Commande executee apres le backup du pod  |

**Exemples** :

```yaml
# Freeze du filesystem (necessite fsfreeze dans l'image)
apiVersion: v1
kind: Pod
metadata:
  name: myapp
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/fsfreeze", "--freeze", "/data"]'
    pre.hook.backup.velero.io/container: myapp
    post.hook.backup.velero.io/command: '["/bin/fsfreeze", "--unfreeze", "/data"]'
    post.hook.backup.velero.io/container: myapp

# PostgreSQL : forcer un checkpoint avant backup
apiVersion: v1
kind: Pod
metadata:
  name: postgres
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/bash", "-c", "PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U postgres -d mydb > /backup/dump.sql"]'
    pre.hook.backup.velero.io/container: postgres

# MySQL : flush tables
apiVersion: v1
kind: Pod
metadata:
  name: mysql
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/bash", "-c", "mysql -u root -p$MYSQL_ROOT_PASSWORD -e \"FLUSH TABLES WITH READ LOCK\""]'
    post.hook.backup.velero.io/command: '["/bin/bash", "-c", "mysql -u root -p$MYSQL_ROOT_PASSWORD -e \"UNLOCK TABLES\""]'
```

**Limites** : le binaire doit etre present dans l'image, le hook s'execute dans le container (pas au niveau K8s), et ca ne gere pas le scale down des workloads.

#### Approche 2 : Cold backup (arret des workloads)

Le script `velero-tools.sh` propose `--cold` pour un arret complet des workloads avant le backup/snapshot :

```bash
# Cold backup Velero (scale down → backup → scale up)
./scripts/velero-tools.sh -b -c daily --ns dokuwiki --cold

# Cold snapshot local (scale down → snapshot → scale up)
./scripts/velero-tools.sh -s -c --ns dokuwiki --cold
```

Le script sauvegarde les replicas de chaque Deployment/StatefulSet, scale tout a 0, attend la fin des pods, execute le backup/snapshot, puis restore les replicas d'origine.

**Avantage** : aucun processus en cours d'ecriture, pas besoin de binaires dans l'image, fonctionne avec n'importe quelle application.

**Inconvenient** : downtime du namespace pendant le backup.

#### Comparaison

|                   | Hooks Velero                  | Cold backup (`--cold`)             |
| ----------------- | ----------------------------- | ---------------------------------- |
| **Downtime**      | Non                           | Oui (pendant le backup)            |
| **Coherence**     | Applicative (flush/freeze)    | Totale (aucun process actif)       |
| **Pre-requis**    | Binaire dans l'image          | Aucun                              |
| **Granularite**   | Par pod                       | Par namespace                      |
| **Cas d'usage**   | Databases (pg_dump, fsfreeze) | Apps sans hooks, backups nocturnes |
| **Configuration** | Annotations sur les pods      | Flag `--cold` a l'execution        |

> **Recommandation** : utiliser les hooks pour les databases en production (pas de downtime), et `--cold` pour les backups nocturnes ou les applications fichier sans mecanisme de flush (DokuWiki, Gitea, etc.).

### Structure du bucket S3

Le bucket S3 contient deux categories de donnees :

```
<bucket>/
  backups/              # Metadata des backups Velero
    <backup-name>/
      velero-backup.json
      <backup-name>.tar.gz     # Manifests K8s (JSON compresse)
      <backup-name>-csi-volumesnapshots.json.gz
      <backup-name>-csi-volumesnapshotcontents.json.gz
      <backup-name>-itemoperations.json.gz
  kopia/                # Donnees des volumes (Kopia repos)
    <namespace>/        # Un repo Kopia par namespace
      kopia.repository  # Config du repo
      kopia.blobcfg     # Config de stockage
      p*/               # Packs (chunks de donnees dedupliques, ~20 Mo)
      q*/               # Index packs (index des chunks)
      xn0_*/            # Epoch markers (points de reference temporels)
      _log_*/           # Logs de maintenance du repo
```

**How it works**:

1. Velero creates a `VolumeSnapshot` for each PVC in the backup
2. The CSI driver (`rook-ceph.rbd.csi.ceph.com`) creates an RBD snapshot on the Ceph cluster
3. The **node-agent** (data mover) reads the snapshot data and uploads it to S3 (Rook-Ceph RGW)
4. Backup metadata (resource manifests + snapshot references) is stored in S3
5. The local CSI snapshot is cleaned up after data movement

**Restore**:

1. Velero reads backup metadata from S3
2. The node-agent downloads volume data from S3
3. Recreates PVCs with the restored data
4. Recreates K8s resources

## Dependencies

| Dependency                                             | Required | Description                               |
| ------------------------------------------------------ | -------- | ----------------------------------------- |
| `features.s3.enabled`                                  | Yes      | S3 object storage for backup metadata     |
| `features.s3.provider: "rook"`                         | Yes      | Rook-Ceph as S3 provider                  |
| `features.storage.enabled`                             | Yes      | Distributed storage (Rook-Ceph)           |
| `csi-external-snapshotter`                             | Yes      | VolumeSnapshot CRDs (deployed at wave 55) |
| `features.monitoring.enabled`                          | Optional | Prometheus metrics + alerts               |
| `features.kyverno.enabled`                             | Optional | PolicyException for SA token mount        |
| `features.networkPolicy.defaultDenyPodIngress.enabled` | Optional | Network policy for Velero traffic         |

## Dashboard (Velero UI)

### Overview

[Velero UI](https://github.com/otwld/velero-ui) (OTWLD) provides a web interface for managing Velero backups, restores, and schedules. It is deployed as a separate Helm chart (`otwld/velero-ui` from `https://helm.otwld.com/`) within the same ArgoCD Application.

### Configuration

| Parameter | Dev | Prod | Description |
|-----------|-----|------|-------------|
| `velero.dashboard.enabled` | `true` | `true` | Enable Velero UI dashboard |
| `velero.dashboard.version` | `0.14.0` | `0.14.0` | Helm chart version (Renovate-managed) |
| `velero.dashboard.resources` | Minimal | Production | CPU/memory requests and limits |

### Access

- **URL**: `https://velero.<domain>` (e.g., `https://velero.k8s.lan`)
- **Routing**: HTTPRoute (Gateway API) or ApisixRoute, deployed conditionally
- **Service**: `velero-ui` ClusterIP on port 3000

### Authentication

| SSO enabled | Provider | Authentication method |
|-------------|----------|-----------------------|
| `true` | `keycloak` | Native OIDC via `OAUTH_*` environment variables (no oauth2-proxy) |
| `false` | - | Basic auth (default: admin/admin) |

When Keycloak OIDC is enabled:
- A PostSync Job creates/updates the `velero-ui` client in Keycloak realm `k8s`
- The client secret is stored in SOPS-encrypted secrets (`secrets/dev/` and `secrets/prod/`)
- The Root CA cert is mounted via ExternalSecret (`root-ca`) for TLS validation towards Keycloak (`NODE_EXTRA_CA_CERTS`)
- Redirect URI: `https://velero.<domain>/login`

### Network Policies

When `features.networkPolicy.ingressPolicy.enabled` is active, provider-specific Cilium/Calico ingress policies are deployed to allow traffic to the Velero UI service (port 3000) only from the configured gateway provider's namespace:

| Provider | Cilium `fromEndpoints` namespace | Calico `namespaceSelector` |
|----------|----------------------------------|---------------------------|
| `apisix` | `apisix` | `apisix` |
| `istio` | `istio-system` | `istio-system` |
| `traefik` | `traefik` | `traefik` |
| `nginx-gwf` | `nginx-gateway` | `nginx-gateway` |
| `envoy-gateway` | `envoy-gateway-system` | `envoy-gateway-system` |
| `cilium` | `kube-system` | `kube-system` |

### Dependencies (Dashboard)

| Dependency | Required | Description |
|------------|----------|-------------|
| `features.gatewayAPI.enabled` | Yes | Gateway routing (HTTPRoute or ApisixRoute) |
| `features.sso.enabled` + `keycloak` | Optional | Keycloak OIDC authentication |
| `features.networkPolicy.ingressPolicy.enabled` | Optional | Provider-specific ingress policy for dashboard traffic |

## Configuration

### Feature flags (`config/config.yaml`)

```yaml
features:
  backup:
    enabled: true
    provider: "velero"
```

### Per-environment config (`config/dev.yaml`, `config/prod.yaml`)

| Parameter                                | Dev         | Prod        | Description                              |
| ---------------------------------------- | ----------- | ----------- | ---------------------------------------- |
| `velero.version`                         | `11.3.2`    | `11.3.2`    | Helm chart version                       |
| `velero.pluginAws.version`               | `v1.13.2`   | `v1.13.2`   | AWS plugin version                       |
| `velero.schedule.cron`                   | `0 2 * * *` | `0 1 * * *` | Backup schedule (cron)                   |
| `velero.schedule.ttl`                    | `72h`       | `720h`      | Backup retention (TTL)                   |
| `velero.resources`                       | Minimal     | Production  | Server resources                         |
| `velero.nodeAgent.enabled`               | `true`      | `true`      | Data mover (uploads CSI snapshots to S3) |
| `velero.nodeAgent.resources`             | Minimal     | Production  | Node-agent resources                     |
| `velero.backup.defaultVolumesToFsBackup` | `false`     | `false`     | Disabled (using CSI snapshots)           |
| `velero.backup.defaultSnapshotMoveData`  | `true`      | `true`      | Upload CSI snapshot data to S3 for DR    |

### Dependance au node-agent

Le **node-agent** est un DaemonSet qui tourne en root sur chaque noeud. Il est responsable du transfert des donnees vers S3. Toutes les combinaisons ne le necessitent pas :

| `defaultVolumesToFsBackup` | `defaultSnapshotMoveData` | `nodeAgent.enabled` requis | Mode                        | Donnees en S3             |
| -------------------------- | ------------------------- | -------------------------- | --------------------------- | ------------------------- |
| `false`                    | `false`                   | **Non**                    | CSI only (snapshots locaux) | Non (metadata uniquement) |
| `false`                    | `true`                    | **Oui**                    | CSI + Data Movement         | Oui (via snapshot)        |
| `true`                     | `false`                   | **Oui**                    | File-System Backup (FSB)    | Oui (fichier par fichier) |
| `true`                     | `true`                    | **Oui**                    | FSB + Move (non recommande) | Oui                       |

**Resume** : le node-agent est requis des qu'on veut envoyer les donnees des volumes en S3, que ce soit via FSB (`defaultVolumesToFsBackup: true`) ou via data movement (`defaultSnapshotMoveData: true`). Sans node-agent, seuls les manifests K8s et les references aux snapshots locaux sont sauvegardes en S3.

## Resources

### Helm Chart

- **Chart**: `vmware-tanzu/velero` v11.3.2
- **App version**: 1.17.1
- **Repository**: https://vmware-tanzu.github.io/helm-charts

### Created Resources

| Resource                        | Type                | Description                                           |
| ------------------------------- | ------------------- | ----------------------------------------------------- |
| `namespace.yaml`                | Namespace           | Namespace with PSA labels (privileged for node-agent) |
| `objectbucketclaim.yaml`        | ObjectBucketClaim   | S3 bucket via Rook-Ceph (PreSync)                     |
| `velero-s3-credentials.yaml`    | Job + RBAC          | PreSync Job creating credentials Secret + BSL         |
| `volumesnapshotclass.yaml`      | VolumeSnapshotClass | Ceph RBD snapshot class with Velero label             |
| `kyverno-policy-exception.yaml` | PolicyException     | SA token mount for K8s API access                     |
| `kustomize/monitoring/`         | PrometheusRules     | Backup failure/missing alerts                         |

### S3 Credentials Flow (PreSync)

1. **PreSync wave 0**: `ObjectBucketClaim` creates a bucket in Rook-Ceph ObjectStore
2. **PreSync wave 1**: Job reads OBC Secret/ConfigMap and creates:
   - `velero-s3-credentials` Secret (Velero AWS credentials format)
   - `default` BackupStorageLocation CR pointing to the S3 bucket
3. **Sync**: Velero starts with credentials available

### CSI Snapshot Flow

1. `VolumeSnapshotClass` `ceph-block-snapshot` is deployed with label `velero.io/csi-volumesnapshot-class: "true"`
2. Velero auto-discovers this class for volumes using the `rook-ceph.rbd.csi.ceph.com` CSI driver
3. During backup, Velero creates `VolumeSnapshot` CRs for each PVC
4. The Ceph RBD CSI driver creates RBD snapshots on the Ceph cluster

### Prometheus Alerts

| Alert                           | Severity | Description                 |
| ------------------------------- | -------- | --------------------------- |
| `VeleroBackupFailed`            | warning  | Backup failed (15m)         |
| `VeleroBackupFailingPersistent` | critical | Backup failing for 12h      |
| `VeleroNoRecentBackup`          | critical | No successful backup in 25h |
| `VeleroBackupPartialFailures`   | warning  | >50% partial failures       |

## Known Issues

### CRD management (`upgradeCRDs: false`)

The Velero Helm chart provides a PreSync hook Job (`upgradeCRDs: true`) to upgrade CRDs on each Helm release. This Job uses a `kubectl` init container (default: `bitnamilegacy/kubectl`) that copies `sh` and `kubectl` binaries to `/tmp` via emptyDir, then the main Velero container (distroless, no shell) runs `/tmp/sh` to apply CRDs.

**Problem**: This mechanism is broken because no available kubectl image provides statically-linked `sh` + `kubectl` binaries that work when copied into the distroless Velero container.

| Image                                   | Result                                                          |
| --------------------------------------- | --------------------------------------------------------------- |
| `bitnamilegacy/kubectl:1.34`            | Tag doesn't exist (bitnamilegacy is EOL/unmaintained)           |
| `bitnami/kubectl:latest`                | `/tmp/sh` fails with `libreadline.so.8` (glibc dynamic linking) |
| `cgr.dev/chainguard/kubectl:latest-dev` | `/tmp/sh` fails with `libcrypt.so.1` (musl dynamic linking)     |
| `rancher/kubectl:v1.34.4`               | No `/bin/sh` at all (distroless)                                |
| `registry.k8s.io/kubectl:v1.32.4`       | No `/bin/sh` at all (distroless)                                |

**Solution**: We set `upgradeCRDs: false` and let **ArgoCD manage CRDs directly** from the chart's `crds/` directory (13 CRDs). ArgoCD renders CRDs with `--include-crds` and applies them during each sync, which is actually more reliable than the Helm hook approach.

**Upstream issues**:

- [vmware-tanzu/helm-charts#698](https://github.com/vmware-tanzu/helm-charts/issues/698) - Migration plan for bitnami kubectl image
- [bitnami/charts#36357](https://github.com/bitnami/charts/issues/36357) - kubectl tag missing for K8s >= 1.34

> **Note**: If upstream resolves the kubectl image issue, `upgradeCRDs: true` can be re-enabled by updating `applicationset.yaml`.

### HOME=/scratch (workaround Kopia distroless)

L'image Velero est basee sur un runtime distroless qui definit `HOME=/nonexistent` (repertoire en lecture seule). Kopia (l'uploader utilise pour le data movement) a besoin d'ecrire ses fichiers de configuration dans `~/.config/kopia/`.

**Symptome** : `mkdir /nonexistent: read-only file system` dans les logs des DataUploads.

**Solution** : on redirige `HOME` vers `/scratch` (un volume `emptyDir` deja monte par le chart) via `configuration.extraEnvVars`. Cette variable est utilisee par le chart Helm pour **les deux** composants (server Deployment et node-agent DaemonSet).

> **Note** : `extraEnvVars` au niveau racine des values Helm ou sous `nodeAgent:` ne fonctionne pas. Seul `configuration.extraEnvVars` est pris en compte par les templates du chart.

## Scripts

Un script unifie `scripts/velero-tools.sh` est fourni pour simplifier les operations courantes. L'interface est composable : on choisit un **type** (`-b` backup ou `-s` snapshot) puis une **action** (`-c` create, `-l` list, `-r` restore, `-d` delete).

```
velero-tools.sh <type> <action> [args...]

Type:    -b, --backup     Velero backup (S3)
         -s, --snapshot   Local CSI snapshot (Ceph)

Action:  -c, --create     Create (defaut si omis)
         -l, --list       List
         -r, --restore    Restore
         -d, --delete     Delete
```

**Backup** :

| Commande                   | Description                           |
| -------------------------- | ------------------------------------- |
| `-b -c <name> [options]`   | Creer un backup Velero vers S3        |
| `-b -l`                    | Lister les backups Velero             |
| `-b -l <name>`             | Details d'un backup (describe + logs) |
| `-b -r <name> [--ns <ns>]` | Restaurer un backup depuis S3         |
| `-b -d <name> [--yes]`     | Supprimer un backup Velero            |

**Snapshot** (flags nommes, `--pvc` optionnel = tous les PVCs du namespace) :

| Commande                                            | Description                                      |
| --------------------------------------------------- | ------------------------------------------------ |
| `-s -c --ns <ns> --pvc <pvc>`                       | Snapshot un PVC                                  |
| `-s -c --ns <ns>`                                   | Snapshot **tous** les PVCs du namespace          |
| `-s -l [--ns <ns>]`                                 | Lister les snapshots                             |
| `-s -r --ns <ns> --pvc <p> --snap <s> --deploy <d>` | Restaurer un PVC depuis un snapshot              |
| `-s -r --ns <ns>`                                   | Restaurer **tous** les PVCs (derniers snapshots) |
| `-s -d --ns <ns> --snap <snap>`                     | Supprimer un snapshot                            |
| `-s -d --ns <ns>`                                   | Supprimer **tous** les snapshots du namespace    |
| `-l`                                                | Lister tout (backups + snapshots)                |

> **Note** : `-c` est optionnel (action par defaut). L'ordre des flags est libre : `-b -r` et `-r -b` sont equivalents.

```bash
# Aide
./scripts/velero-tools.sh --help

# Lister
./scripts/velero-tools.sh -l                                        # Tout (backups + snapshots)
./scripts/velero-tools.sh -b -l                                     # Backups uniquement
./scripts/velero-tools.sh -b -l daily                               # Details du backup 'daily'
./scripts/velero-tools.sh -s -l                                     # Snapshots uniquement
./scripts/velero-tools.sh -s -l --ns dokuwiki                       # Snapshots d'un namespace

# Backup Velero (→ S3)
./scripts/velero-tools.sh -b -c daily --ns keycloak --wait          # Creer (-c optionnel)
./scripts/velero-tools.sh -b -c full --exclude-ns velero,rook-ceph  # Tout sauf certains ns
./scripts/velero-tools.sh -b -c meta --ns keycloak --no-volumes     # Metadata uniquement (pas de volumes)
./scripts/velero-tools.sh -b -c daily --ns keycloak --wait --details  # Creer + details complets
./scripts/velero-tools.sh -b -r daily --ns keycloak                 # Restaurer
./scripts/velero-tools.sh -b -d daily                               # Supprimer

# Snapshot local (Ceph) - un PVC
./scripts/velero-tools.sh -s -c --ns dokuwiki --pvc dokuwiki-data   # Snapshot un PVC
./scripts/velero-tools.sh -s -r --ns dokuwiki --pvc dokuwiki-data \
    --snap dokuwiki-data-snap-20260220 --deploy dokuwiki             # Restaurer un PVC
./scripts/velero-tools.sh -s -d --ns dokuwiki --snap snap-name      # Supprimer un snapshot

# Snapshot local (Ceph) - tout le namespace
./scripts/velero-tools.sh -s -c --ns dokuwiki                       # Snapshot tous les PVCs
./scripts/velero-tools.sh -s -r --ns dokuwiki                       # Restaurer tous les PVCs
./scripts/velero-tools.sh -s -d --ns dokuwiki                       # Supprimer tous les snapshots

# Cold backup/snapshot (scale down → backup/snap → scale up)
./scripts/velero-tools.sh -b -c daily --ns dokuwiki --cold          # Backup a froid
./scripts/velero-tools.sh -s -c --ns dokuwiki --cold                # Snapshot tous les PVCs a froid
./scripts/velero-tools.sh -s -c --ns dokuwiki --pvc data --cold     # Snapshot un PVC a froid
```

**Restore all** (`-s -r --ns <ns>`) : le script detecte automatiquement le dernier snapshot de chaque PVC, sauvegarde les replicas de tous les Deployments/StatefulSets, scale tout a 0, restaure les PVCs, puis restore les replicas d'origine.

**Cold mode** (`--cold`) : scale down tous les workloads du namespace avant l'operation, puis restore les replicas d'origine apres. Garantit la coherence applicative (pas de donnees en memoire/buffers non flush). Utile pour les apps sans crash-recovery propre (SQLite, DokuWiki, fichiers). Pour les backup Velero, `--cold` implique `--wait` (le script attend la fin du backup avant de scale up).

## Operations

### Lancer un backup manuel

```bash
# Backup complet du cluster
velero backup create <backup-name>

# Backup d'un namespace specifique
velero backup create <backup-name> --include-namespaces <namespace>

# Backup avec label selector
velero backup create <backup-name> --selector app=myapp

# Suivre la progression
velero backup describe <backup-name> --details

# Attendre la fin du backup
velero backup create <backup-name> --wait
```

### Lister et inspecter les backups

```bash
# Lister tous les backups
velero backup get

# Details d'un backup (volumes, erreurs, warnings)
velero backup describe <backup-name> --details

# Logs d'un backup
velero backup logs <backup-name>
```

### Supprimer un backup

```bash
# Supprimer un backup (et ses donnees en S3)
velero backup delete <backup-name>

# Supprimer sans confirmation
velero backup delete <backup-name> --confirm

# Supprimer tous les backups (attention !)
velero backup delete --all --confirm
```

> **Note** : la suppression d'un backup supprime aussi les DataUploads associes et les donnees dans le repo Kopia en S3. Les snapshots RBD locaux (si `deletionPolicy: Retain`) ne sont **pas** supprimes par Velero.

### Voir les snapshots

```bash
# VolumeSnapshots crees par Velero (par namespace)
kubectl get volumesnapshots -A

# VolumeSnapshotContents (cluster-wide, reference les snapshots RBD)
kubectl get volumesnapshotcontents

# Detail d'un snapshot (taille, readyToUse, driver)
kubectl get volumesnapshotcontents <name> -o yaml

# DataUploads (progression de l'upload des snapshots vers S3)
kubectl get datauploads -n velero

# DataDownloads (progression du download lors d'un restore)
kubectl get datadownloads -n velero
```

### Restaurer un backup

#### Politique de restauration des ressources existantes

| `--existing-resource-policy` | Comportement                                                                 |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `none` (defaut)              | Les ressources existantes sont **ignorees** (pas de restauration par-dessus) |
| `update`                     | Les ressources existantes sont **mises a jour** avec le contenu du backup    |

> **Important** : pour les PVCs, meme avec `--existing-resource-policy=update`, un PVC existant bound a un PV **ne sera pas ecrase**. Pour restaurer les donnees d'un volume, il faut supprimer le PVC (ou le namespace entier) avant la restauration.

#### Commandes de restauration

```bash
# Restaurer un backup complet
velero restore create --from-backup <backup-name>

# Restaurer un namespace specifique
velero restore create --from-backup <backup-name> --include-namespaces <namespace>

# Restaurer avec ecrasement des ressources existantes (hors PVCs)
velero restore create --from-backup <backup-name> --existing-resource-policy update

# Restaurer en excluant certaines ressources
velero restore create --from-backup <backup-name> --exclude-resources persistentvolumeclaims

# Restaurer dans un namespace different (remapping)
velero restore create --from-backup <backup-name> \
  --namespace-mappings <source>:<destination>

# Restaurer un seul PVC dans un namespace temporaire (pour inspection)
velero restore create --from-backup <backup-name> \
  --include-namespaces <namespace> \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --namespace-mappings <namespace>:<namespace>-restore

# Suivre la progression
velero restore describe <restore-name> --details

# Lister les restores
velero restore get
```

> **Note** : la restauration des volumes en mode CSI + Data Movement telecharge les donnees depuis S3 et recree les PVCs via le node-agent. C'est plus lent qu'un restore depuis un snapshot local (mode CSI only) mais permet la restauration meme si le cluster Ceph original est perdu.

#### Test de restauration valide

Test effectue avec DokuWiki (Deployment + PVC `ceph-block` 1Gi + Service) :

1. **Installation** de DokuWiki dans le namespace `dokuwiki`
2. **Modifications** du contenu du wiki (ajout de pages)
3. **Backup** : `velero backup create dokuwiki-before --include-namespaces dokuwiki --wait` (Completed, 17 items, 1 DataUpload ~3.3 Mo, ~1 min)
4. **Nouvelles modifications** du contenu du wiki (modifications supplementaires)
5. **Suppression** du namespace : `kubectl delete namespace dokuwiki`
6. **Restauration** : `velero restore create dokuwiki-restore --from-backup dokuwiki-before --wait` (Completed, ~1 min)
7. **Verification** : le namespace, Deployment, Service, PVC et les donnees du wiki sont restaures a l'etat du backup. Les modifications faites apres le backup ont bien disparu.

**Procedure recommandee pour un restore complet d'un namespace** :

```bash
# 1. Supprimer le namespace (necessaire pour restaurer les PVCs)
kubectl delete namespace <namespace>

# 2. Restaurer depuis le backup
velero restore create --from-backup <backup-name> --include-namespaces <namespace> --wait

# 3. Verifier
kubectl get pods,pvc,svc -n <namespace>
```

### Inspecter le contenu d'un backup

Velero ne permet pas de parcourir les fichiers a l'interieur d'un backup. Les donnees des volumes sont stockees en format Kopia (chunks dedupliques et compresses). Deux methodes :

**Methode 1 : Restore dans un namespace temporaire**

```bash
# Restaurer les PVCs dans un namespace temporaire
velero restore create inspect-keycloak --from-backup <backup-name> \
  --include-namespaces keycloak \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --namespace-mappings keycloak:keycloak-inspect

# Monter le PVC dans un pod pour explorer les fichiers
kubectl run -n keycloak-inspect inspect-pod --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"inspect","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"<pvc-name>"}}]}}' \
  --restart=Never

kubectl exec -n keycloak-inspect -it inspect-pod -- ls /data

# Nettoyage
kubectl delete namespace keycloak-inspect
```

**Methode 2 : Kopia CLI (acces direct au repo S3)**

```bash
# Se connecter au repo Kopia d'un namespace
kopia repository connect s3 \
  --bucket=<bucket> \
  --endpoint=<rgw-endpoint> \
  --access-key=<key> --secret-access-key=<secret> \
  --prefix=kopia/<namespace>/

# Lister les snapshots
kopia snapshot list

# Monter un snapshot en lecture seule
kopia mount <snapshot-id> /mnt/restore
```

### Gestion des schedules

```bash
# Lister les schedules
velero schedule get

# Declencher un backup immediat depuis un schedule
velero backup create --from-schedule <schedule-name>

# Voir le detail d'un schedule
velero schedule describe <schedule-name>
```

## Disaster Recovery

### Strategie DRP : GitOps rebuild + restauration selective des donnees

> **Important** : une restauration "bare metal" (Velero restore complet sur un cluster vierge) **ne fonctionne pas** de maniere fiable. La strategie validee est de reconstruire l'infrastructure via GitOps en deux phases, en restaurant les PVCs **avant** de deployer les applications stateful.

#### Pourquoi la restauration complete ne fonctionne pas

Un test DRP complet (destruction du cluster, reinstallation RKE2, Velero restore de tout) a revele les problemes suivants :

| Probleme | Detail |
|----------|--------|
| **CiliumClusterwideNetworkPolicy (CCNP)** | Les CCNPs sont des ressources cluster-scoped, non incluses dans un backup Velero namespace-scoped. Sans la CCNP `default-deny-external-egress` (qui autorise cluster, kube-apiserver, host, DNS), les pods ne peuvent pas joindre l'API server |
| **Deny implicite Cilium** | Toute CiliumNetworkPolicy avec des regles egress cree un deny implicite sur tout le trafic egress non explicitement autorise. Les CNPs restaurees sans la base CCNP cassent la connectivite |
| **PSA restricted (CIS hardening)** | RKE2 avec profil CIS enforce PSA `restricted` par defaut sur tous les namespaces. Velero, ArgoCD, et les node-agents necessitent `privileged`. Les namespaces doivent etre pre-labeles avant le restore |
| **StorageClass manquante** | Les DataDownloads (restauration PVC) echouent si la StorageClass (`ceph-block`) n'existe pas encore. Rook-Ceph doit etre operationnel avant de restaurer les volumes |
| **Dependances d'ordre** | Les CRDs, operateurs, et resources d'infrastructure doivent exister avant les CRs applicatives. Un restore massif ne respecte pas cet ordre |
| **ArgoCD auto-sync** | L'auto-sync avec `selfHeal: true` rescale les workloads et recree les PVCs vides, empechant la restauration des donnees. L'ApplicationSet controller regenere les specs des Applications, ecrasant les patches manuels |
| **Pods temporaires Velero** | Les DataDownloads creent des pods temporaires ("expose pods") dans le namespace `velero` qui n'ont pas les labels standard. La CNP doit utiliser `endpointSelector: {}` (tous les pods du namespace) |

### Pre-requis : backup vers un S3 externe

Pour le DRP, les backups doivent etre stockes sur un S3 **externe au cluster** (le S3 Rook-Ceph interne est perdu avec le cluster).

#### Configuration du S3 externe (MinIO)

```bash
# 1. Creer la CiliumNetworkPolicy pour autoriser le trafic vers le S3 externe
#    CRITICAL: utiliser endpointSelector: {} pour couvrir les pods temporaires DataDownload
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: velero-allow-minio-egress
  namespace: velero
spec:
  description: "Allow ALL pods in velero namespace to reach external S3 for DRP"
  endpointSelector: {}
  egress:
    - toCIDR:
        - <S3_IP>/32
      toPorts:
        - ports:
            - port: "<S3_PORT>"
              protocol: TCP
EOF

# 2. Creer le Secret avec les credentials S3
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: velero-s3-external
  namespace: velero
type: Opaque
stringData:
  cloud: |
    [default]
    aws_access_key_id=<ACCESS_KEY>
    aws_secret_access_key=<SECRET_KEY>
EOF

# 3. Creer le BackupStorageLocation pointant vers le S3 externe
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: external
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: velero
  credential:
    name: velero-s3-external
    key: cloud
  config:
    region: minio
    s3ForcePathStyle: "true"
    s3Url: http://<S3_IP>:<S3_PORT>
EOF

# 4. Verifier que le BSL est Available
kubectl get backupstoragelocation -n velero

# 5. Creer un backup complet vers le S3 externe
velero backup create drp-backup --storage-location external --wait
```

### Procedure DRP validee : deploiement en deux phases

La strategie consiste a deployer l'infrastructure en premier (Phase 1), restaurer les PVCs depuis le backup externe, puis deployer les applications stateful (Phase 2) qui trouvent les PVCs avec donnees deja en place.

```
Phase 1: Infrastructure     Phase 2: Restore PVCs    Phase 3: Apps stateful
========================     ====================     =====================
RKE2 + ArgoCD               Velero BSL + CNP         external-dns
Kyverno + PolicyExceptions   Restore 7 PVCs           keycloak
external-secrets             (5 namespaces)           loki
Rook-Ceph (StorageClass)                              tempo
Velero + node-agent
prometheus-stack (CRDs)
cert-manager, cilium, etc.
```

#### Classification des applications

| Categorie | Applications | PVCs | Phase |
|-----------|-------------|------|-------|
| **Infrastructure** (sans donnees persistantes) | kyverno, external-secrets, cert-manager, rook, csi-external-snapshotter, velero, cilium, cnpg-operator, envoy-gateway, kube-vip, alloy, kata-containers, oauth2-proxy, argocd | Aucune | Phase 1 |
| **Infrastructure avec CRDs** (PVCs a gerer) | prometheus-stack | grafana, alertmanager, prometheus (3 PVCs) | Phase 1 + restore |
| **Stateful** (PVCs restaurees avant deploiement) | external-dns, keycloak, loki, tempo | etcd, postgres, storage (4 PVCs) | Phase 3 |

> **Note** : `prometheus-stack` est deploye en Phase 1 car il fournit les CRDs `PrometheusRule` et `ServiceMonitor` dont dependent rook, cilium, et d'autres apps infrastructure.

#### Etape 1 : Reconstruire le cluster + infrastructure

```bash
# 1. Creer le cluster RKE2 vierge
make vagrant-dev-up   # ou equivalent production

# 2. Recuperer le kubeconfig
export KUBECONFIG=vagrant/.kube/config-dev

# 3. Installer ArgoCD (Helm template + apply)
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update argo
kubectl create namespace argo-cd
kubectl create secret generic sops-age-key --namespace argo-cd \
  --from-file=keys.txt=sops/age-dev.key

ARGOCD_VERSION=$(yq -r '.argocd.version' deploy/argocd/apps/argocd/config/dev.yaml)
K8S_VERSION=$(kubectl version -o json | jq -r '.serverVersion.gitVersion' | sed 's/^v//; s/+.*//')
helm template argocd argo/argo-cd --namespace argo-cd \
  --version "$ARGOCD_VERSION" --kube-version "$K8S_VERSION" \
  -f deploy/argocd/argocd-bootstrap-values.yaml | kubectl apply --server-side --force-conflicts -f -
kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=argocd-server \
  -n argo-cd --timeout=5m

# 4. Deployer Kyverno (Phase 1.1)
kubectl apply -f deploy/argocd/apps/kyverno/applicationset.yaml
# Attendre Healthy, puis pre-appliquer toutes les PolicyExceptions :
for pe in deploy/argocd/apps/*/resources/kyverno-policy-exception*.yaml; do
  [ -f "$pe" ] || continue
  ns=$(yq -r '.metadata.namespace' "$pe")
  kubectl create namespace "$ns" 2>/dev/null || true
  kubectl apply -f "$pe"
done

# 5. Deployer external-secrets (Phase 1.2)
kubectl apply -f deploy/argocd/apps/external-secrets/applicationset.yaml
# Attendre Healthy

# 6. Deployer toute l'infrastructure (Phase 2)
for app in cert-manager rook csi-external-snapshotter velero cilium cnpg-operator \
           envoy-gateway kube-vip alloy kata-containers oauth2-proxy argocd prometheus-stack; do
  kubectl apply -f "deploy/argocd/apps/$app/applicationset.yaml"
done

# 7. Attendre Rook (StorageClass) + Velero + prometheus-stack Healthy
kubectl get applications -n argo-cd -w
```

#### Etape 2 : Connecter Velero au S3 externe et restaurer les PVCs

```bash
# 1. Creer la CNP, le Secret et le BSL (voir "Configuration du S3 externe" ci-dessus)

# 2. Verifier que le BSL est Available et le backup visible
kubectl get backupstoragelocation -n velero
kubectl get backups.velero.io -n velero

# 3. Gerer les PVCs monitoring (creees par prometheus-stack en Phase 1)
#    Suspendre l'ApplicationSet controller pour eviter l'auto-sync
kubectl scale deploy argocd-applicationset-controller -n argo-cd --replicas=0
kubectl patch application prometheus-stack -n argo-cd --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'

#    Arreter l'operateur + workloads (l'operateur recree les PVCs sinon)
kubectl scale deploy prometheus-stack-kube-prom-operator -n monitoring --replicas=0
kubectl scale sts alertmanager-prometheus-stack-kube-prom-alertmanager -n monitoring --replicas=0
kubectl scale sts prometheus-prometheus-stack-kube-prom-prometheus -n monitoring --replicas=0
kubectl scale deploy prometheus-stack-grafana -n monitoring --replicas=0

#    Supprimer les PVCs vides (retirer les finalizers pour forcer la suppression)
for pvc in $(kubectl get pvc -n monitoring -o name); do
  kubectl patch "$pvc" -n monitoring -p '{"metadata":{"finalizers":null}}' --type=merge
done
kubectl delete pvc --all -n monitoring --wait=false
# Attendre la suppression complete

# 4. Restaurer TOUTES les PVCs (5 namespaces, 7 PVCs)
kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: drp-pvc-restore
  namespace: velero
spec:
  backupName: drp-backup
  includedNamespaces:
    - external-dns
    - keycloak
    - loki
    - monitoring
    - tempo
  includedResources:
    - persistentvolumeclaims
    - persistentvolumes
  restorePVs: true
EOF

# Suivre la progression
kubectl get datadownloads.velero.io -n velero -w

# 5. Verifier que les 7 PVCs sont Bound
kubectl get pvc -A
```

#### Etape 3 : Deployer les applications stateful

```bash
# 1. Deployer les 4 apps stateful (PVCs deja en place avec donnees)
for app in external-dns keycloak loki tempo; do
  kubectl apply -f "deploy/argocd/apps/$app/applicationset.yaml"
done

# 2. Remonter le monitoring
kubectl scale deploy prometheus-stack-kube-prom-operator -n monitoring --replicas=1
kubectl patch application prometheus-stack -n argo-cd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# 3. Re-activer l'ApplicationSet controller
kubectl scale deploy argocd-applicationset-controller -n argo-cd --replicas=1

# 4. Attendre que toutes les apps soient Healthy
kubectl get applications -n argo-cd -w
```

#### Etape 4 : Verification

```bash
# Verifier 19/19 apps Synced + Healthy
kubectl get applications -n argo-cd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# Verifier les 7 PVCs Bound
kubectl get pvc -A

# Verifier les pods stateful
for ns in external-dns keycloak loki monitoring tempo; do
  echo "--- $ns ---"
  kubectl get pods -n $ns
done

# Mettre a jour le kubeconfig avec la VIP kube-vip
KUBE_VIP=$(yq -r '.features.loadBalancer.staticIPs.kubernetesApi' deploy/argocd/config/config.yaml)
# Regenerer le kubeconfig avec la VIP
```

### Test DRP valide

Test effectue le 2026-02-21 sur cluster dev (RKE2 v1.34.4, 1 noeud) :

| Metrique | Valeur |
|----------|--------|
| **Cluster** | RKE2 v1.34.4+rke2r1, Cilium CNI, Rook-Ceph |
| **Backup source** | MinIO externe (192.168.1.100:9000), bucket `velero` |
| **PVCs restaurees** | 7/7 (5 namespaces) |
| **DataDownloads** | 7 completed (~778 Mo total) |
| **Apps finales** | 19/19 Synced + Healthy |
| **Duree totale** | ~15 min (cluster ready → all apps healthy) |

**PVCs restaurees** :

| Namespace | PVC | Taille |
|-----------|-----|--------|
| `external-dns` | `data-external-dns-etcd-0` | 8 Gi (144 Mo donnees) |
| `keycloak` | `keycloak-db-1` | 1 Gi (290 Mo donnees) |
| `loki` | `storage-loki-0` | 1 Gi (288 Mo donnees) |
| `monitoring` | `prometheus-stack-grafana` | 1 Gi (54 Mo donnees) |
| `monitoring` | `alertmanager-...-0` | 1 Gi |
| `monitoring` | `prometheus-...-0` | 2 Gi |
| `tempo` | `storage-tempo-0` | 5 Gi (214 octets) |

### Restauration partielle (namespace unique)

Pour restaurer un seul namespace applicatif (ex: apres suppression accidentelle) :

```bash
# 1. Supprimer le namespace (necessaire pour restaurer les PVCs)
kubectl delete namespace <namespace>

# 2. Restaurer depuis le backup
velero restore create --from-backup <backup-name> --include-namespaces <namespace> --wait

# 3. Verifier
kubectl get pods,pvc,svc -n <namespace>
```

> **Important** : cette methode fonctionne car le reste de l'infrastructure (StorageClass, CNI, CRDs) est deja en place. C'est le scenario le plus simple et le plus fiable.

### Pieges a eviter

| Piege | Consequence | Prevention |
|-------|-------------|------------|
| CNP avec label specifique (`app.kubernetes.io/instance`) | Les pods temporaires DataDownload n'ont pas ces labels, timeout 6min | Utiliser `endpointSelector: {}` dans la CNP du namespace `velero` |
| Deployer apps stateful avant restauration PVCs | PVCs vides creees par ArgoCD, auto-sync empeche le remplacement | Deployer infra d'abord, restaurer PVCs, puis deployer apps stateful |
| prometheus-operator actif pendant suppression PVCs | L'operateur recree immediatement les PVCs alertmanager/prometheus | Arreter l'operateur (`--replicas=0`) avant de supprimer les PVCs |
| PVCs avec finalizer `kubernetes.io/pvc-protection` | PVC bloquee en `Terminating` indefiniment | Retirer le finalizer avant suppression : `kubectl patch pvc -p '{"metadata":{"finalizers":null}}' --type=merge` |
| ApplicationSet controller actif pendant patches | Regenere les specs Applications, ecrase la suppression d'auto-sync | Suspendre le controller (`--replicas=0`) avant de patcher les Applications |
| Restore complet sur cluster vierge | PSA restricted bloque les pods, StorageClass manquante, pas d'ordre | Toujours reconstruire via GitOps en phases |

## Troubleshooting

### Backup not running

```bash
kubectl get schedules.velero.io -n velero
kubectl get backups.velero.io -n velero
velero backup describe <backup-name> --details
```

### S3 credentials issue

```bash
# Check OBC status
kubectl get objectbucketclaim -n velero
# Check credentials Secret
kubectl get secret velero-s3-credentials -n velero -o jsonpath='{.data.cloud}' | base64 -d
# Check BSL status
kubectl get backupstoragelocation -n velero
```

### CSI snapshot not working

```bash
# Check VolumeSnapshotClass exists and has Velero label
kubectl get volumesnapshotclass ceph-block-snapshot -o yaml

# Check CSI driver is running
kubectl get csidrivers rook-ceph.rbd.csi.ceph.com

# Check VolumeSnapshots created by a backup
kubectl get volumesnapshots -n <namespace>

# Check snapshot controller logs
kubectl logs -n kube-system -l app=snapshot-controller

# Check node-agent (data mover) logs
kubectl logs -n velero -l name=node-agent --tail=50

# Check DataUpload/DataDownload CRs (data movement status)
kubectl get datauploads -n velero
kubectl get datadownloads -n velero
```

### Force re-run credentials Job

Delete the completed Job to trigger a new PreSync:

```bash
kubectl delete job velero-s3-credentials -n velero
# Then force an ArgoCD sync
```
