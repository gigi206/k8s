# KubeVirt

KubeVirt permet d'exécuter des machines virtuelles (VMs) sur Kubernetes en les gérant comme des ressources natives. Ce déploiement inclut trois composants : l'opérateur KubeVirt (gestion du cycle de vie des VMs), CDI (import et gestion des images disque), et kubevirt-manager (interface web).

## Vue d'Ensemble

**Deployment** : Kustomize remote resources (opérateurs) + Helm chart (kubevirt-manager)
**Namespaces** : `kubevirt` (opérateur + VMs) et `cdi` (Containerized Data Importer)
**Feature flag** : `features.kubevirt.enabled`
**Chart** : [christianhuth/kubevirt-manager](https://charts.christianhuth.de)

## Composants

| Composant | Version | Type source | Description |
|-----------|---------|-------------|-------------|
| KubeVirt Operator | v1.7.1 | Kustomize remote | Opérateur VM (CRDs + contrôleurs) |
| CDI Operator | v1.64.0 | Kustomize remote | Import et gestion des images disque |
| kubevirt-manager | 0.5.2 (app 1.5.4) | Helm chart | Interface web de gestion des VMs |
| KubeVirt CR | - | Kustomize local | Configuration de l'instance KubeVirt |
| CDI CR | - | Resource | Configuration de l'instance CDI |

## Prérequis

### Hardware

- **Virtualisation matérielle** : Les nodes doivent supporter Intel VT-x ou AMD-V
- **KVM disponible** : `/dev/kvm` doit exister sur les nodes (sauf mode émulation)
- **Nested virtualization** : Requise si le cluster tourne dans des VMs

Vérification sur un node :

```bash
# Vérifier le support KVM
ls -la /dev/kvm

# Vérifier la virtualisation nested (si dans une VM)
cat /sys/module/kvm_intel/parameters/nested  # Intel
cat /sys/module/kvm_amd/parameters/nested    # AMD
```

### Mode Émulation

Si `/dev/kvm` n'est pas disponible, activer le mode émulation :

```yaml
# config/config.yaml
features:
  kubevirt:
    enabled: true
    emulation: true
```

Le mode émulation est beaucoup plus lent mais permet de tester sur des environnements sans virtualisation matérielle.

### Dépendances

- **Stockage RWX** : Requis pour la live migration. Deux options :
  - **Rook CephFS** (`rook.cephfs.enabled: true`) : stockage distribué natif RWX
  - **Longhorn** : fournit le RWX via NFS nativement, pas de config supplémentaire
- **Multus CNI** (`cni.multus.enabled: true`) : Requis pour le réseau bridge des VMs. Activé automatiquement par `resolve_dependencies` dans `deploy-applicationsets.sh`
- **ArgoCD kustomize.buildOptions** : `--load-restrictor LoadRestrictionsNone` requis pour les kustomize remote resources (opérateurs). C'est un changement **global** d'ArgoCD

## Feature Flags

| Flag | Description |
|------|-------------|
| `features.kubevirt.enabled` | Active le déploiement de KubeVirt |
| `features.kubevirt.emulation` | Active l'émulation logicielle (sans `/dev/kvm`) |

## Configuration

### Gestion des Versions

Les versions des opérateurs sont gérées dans les fichiers kustomization.yaml (URLs remote) :

- **KubeVirt Operator** : `kustomize/kubevirt-operator/kustomization.yaml` (URL GitHub release)
- **CDI Operator** : `kustomize/cdi-operator/kustomization.yaml` (URL GitHub release)
- **kubevirt-manager** : `config/dev.yaml` et `config/prod.yaml` (`kubevirt.manager.version` et `kubevirt.manager.appVersion`)

Les versions des opérateurs sont trackées par Renovate via des custom regex managers.

### Live Migration

Les paramètres de live migration sont configurés par environnement :

| Paramètre | Dev | Prod | Description |
|-----------|-----|------|-------------|
| `bandwidthPerMigration` | 64Mi | 128Mi | Bande passante par migration |
| `parallelMigrationsPerCluster` | 5 | 10 | Migrations parallèles max (cluster) |
| `parallelOutboundMigrationsPerNode` | 2 | 3 | Migrations parallèles max (par node) |

Ces valeurs sont injectées via des patches kustomize dans l'ApplicationSet (Go templates).

Paramètres fixes dans le CR KubeVirt :

- `completionTimeoutPerGiB: 800` : Timeout par GiB de données
- `progressTimeout: 150` : Timeout si pas de progression
- `workloadUpdateStrategy: LiveMigrate` : Stratégie de mise à jour des workloads
- `vmRolloutStrategy: LiveUpdate` : Stratégie de rollout des VMs

### Réseau Bridge (Multus)

Quand Multus est activé, un `NetworkAttachmentDefinition` crée un bridge Linux (`br-kubevirt`) pour les interfaces réseau secondaires des VMs :

- **Bridge** : `br-kubevirt` (auto-créé par le CNI bridge plugin sur chaque node)
- **IPAM** : Whereabouts avec range `10.200.0.0/24`
- **MAC spoofing** : Protection activée (`macspoofchk: true`)

Les VMs utilisant ce bridge en interface **secondaire** supportent la live migration. Seul le bridge sur l'interface **primaire** (pod network) bloque la migration.

## Architecture

```
kubevirt (namespace)
├── KubeVirt Operator (Deployment)
│   └── virt-api, virt-controller, virt-handler (DaemonSet)
├── KubeVirt CR (configuration)
├── kubevirt-manager (Helm - Web UI)
├── NetworkAttachmentDefinition (bridge, si Multus)
└── ServiceMonitors (si monitoring activé)

cdi (namespace)
├── CDI Operator (Deployment)
│   └── cdi-apiserver, cdi-deployment, cdi-uploadproxy
├── CDI CR (configuration)
└── ServiceMonitors (si monitoring activé)
```

### Sources dans l'ApplicationSet

L'ApplicationSet utilise plusieurs sources conditionnelles :

1. **Namespaces** (si CIS) : `resources/namespace.yaml`, `resources/namespace-cdi.yaml`
2. **Kyverno PolicyExceptions** (si Kyverno) : Autorise le montage de SA tokens
3. **KubeVirt Operator** : `kustomize/kubevirt-operator/` (remote resource)
4. **CDI Operator** : `kustomize/cdi-operator/` (remote resource)
5. **KubeVirt CR** : `kustomize/kubevirt-cr/` (avec patches dynamiques)
6. **CDI CR** : `resources/cdi-cr.yaml`
7. **Bridge NAD** (si Multus) : `kustomize/network-attachment-definition/`
8. **kubevirt-manager** : Chart Helm `christianhuth/kubevirt-manager`
9. **Network policies** (si activées) : Cilium ou Calico selon le CNI
10. **HTTPRoute** (si Gateway API) : `kustomize/httproute/`
11. **Monitoring** (si activé) : `kustomize/monitoring/`

### Kustomize Remote Resources

Les opérateurs KubeVirt et CDI sont déployés via des remote kustomize resources pointant vers les release artifacts GitHub upstream :

```yaml
# kustomize/kubevirt-operator/kustomization.yaml
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.7.1/kubevirt-operator.yaml

# kustomize/cdi-operator/kustomization.yaml
resources:
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.64.0/cdi-operator.yaml
```

Cela nécessite `--load-restrictor LoadRestrictionsNone` dans les `kustomize.buildOptions` d'ArgoCD. C'est un changement global qui affecte toutes les applications ArgoCD utilisant Kustomize.

## Monitoring

Quand `features.monitoring.enabled` est actif, les ServiceMonitors suivants sont déployés :

- **kubevirt-servicemonitor** : Métriques de l'opérateur KubeVirt (virt-api, virt-controller, virt-handler)
- **cdi-servicemonitor** : Métriques de l'opérateur CDI (apiserver, deployment, uploadproxy)

Des Services dédiés pour les métriques sont créés pour exposer les endpoints :
- `kubevirt-metrics-service` (namespace kubevirt)
- `cdi-metrics-service` (namespace cdi)

## Différences Dev/Prod

| Aspect | Dev | Prod |
|--------|-----|------|
| Auto-sync | Activé | Désactivé |
| Bande passante migration | 64Mi | 128Mi |
| Migrations parallèles (cluster) | 5 | 10 |
| Migrations parallèles (par node) | 2 | 3 |

## Troubleshooting

### Mode émulation non actif

**Symptôme** : Les virt-handler pods crashent avec des erreurs KVM

```bash
# Vérifier si /dev/kvm existe sur les nodes
kubectl debug node/<node-name> -it --image=busybox -- ls -la /dev/kvm

# Vérifier la config émulation
kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}'
```

**Solution** : Activer `features.kubevirt.emulation: true` dans `config/config.yaml`.

### CRDs non synchronisés

**Symptôme** : ArgoCD montre des erreurs "resource not found" pour les CRDs KubeVirt/CDI

```bash
# Vérifier les CRDs
kubectl get crd | grep kubevirt
kubectl get crd | grep cdi

# Vérifier l'opérateur
kubectl get pods -n kubevirt -l kubevirt.io=virt-operator
kubectl get pods -n cdi -l cdi.kubevirt.io=cdi-operator
```

**Solution** : Les CRDs sont déployés par les opérateurs. Vérifier que les opérateurs sont en état Running. Si les CRDs n'apparaissent pas, forcer un refresh ArgoCD.

### Échec de live migration

**Symptôme** : Les migrations restent en état `Scheduling` ou `Failed`

```bash
# Vérifier les migrations
kubectl get vmim -A

# Détails d'une migration
kubectl describe vmim <migration-name> -n <namespace>

# Vérifier le stockage
kubectl get pvc -n <namespace>
kubectl get sc
```

**Causes courantes** :
- **Stockage non RWX** : La live migration nécessite un stockage ReadWriteMany. Selon le provider : Rook → vérifier `rook.cephfs.enabled: true` ; Longhorn → RWX natif via NFS, pas de config supplémentaire
- **Bridge sur pod network** : Le bridge sur l'interface réseau primaire bloque la migration. Utiliser `masquerade` pour le pod network et le bridge uniquement en interface secondaire via Multus
- **Bande passante insuffisante** : Augmenter `bandwidthPerMigration` dans la config
- **Timeout** : Augmenter `completionTimeoutPerGiB` ou `progressTimeout` dans le CR KubeVirt

### Multus non installé

**Symptôme** : Le `NetworkAttachmentDefinition` n'est pas créé ou les VMs ne peuvent pas utiliser le bridge

```bash
# Vérifier que Multus est déployé
kubectl get pods -A | grep multus

# Vérifier les NADs
kubectl get net-attach-def -n kubevirt
```

**Solution** : Multus est activé automatiquement par `resolve_dependencies` quand KubeVirt est activé. Vérifier que `cni.multus.enabled: true` dans la config.

### kustomize.buildOptions manquant

**Symptôme** : Erreur ArgoCD "accumulating resources: URL is not allowed"

**Solution** : Vérifier que `--load-restrictor LoadRestrictionsNone` est présent dans la configuration ArgoCD `kustomize.buildOptions`. Ce paramètre est nécessaire pour les remote kustomize resources utilisées par les opérateurs.

## Docs

- [KubeVirt Documentation](https://kubevirt.io/user-guide/)
- [CDI Documentation](https://github.com/kubevirt/containerized-data-importer)
- [kubevirt-manager](https://kubevirt-manager.io/)
- [Live Migration Guide](https://kubevirt.io/user-guide/compute/live_migration/)
- [Networking Guide](https://kubevirt.io/user-guide/network/interfaces_and_networks/)
