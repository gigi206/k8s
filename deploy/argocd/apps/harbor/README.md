# Harbor

Cet ApplicationSet deploie Harbor, un registre de conteneurs open-source avec gestion des images, scan de vulnerabilites (Trivy), controle d'acces RBAC et authentification OIDC via Keycloak.

## Vue d'ensemble

**Harbor** est deploye via le chart Helm officiel (`helm.goharbor.io`) avec les integrations suivantes :

- **Stockage** : PVC (avec PreSync hook pour attendre le storage)
- **Base de donnees** : PostgreSQL externe via CNPG (CloudNativePG) avec failover automatique
- **Monitoring** : ServiceMonitor + PrometheusRules + PodMonitor CNPG (alertes core, registry, database, trivy)
- **SSO/OIDC** : Double couche - SecurityPolicy Envoy Gateway (web UI) + configuration OIDC native Harbor (Docker CLI)
- **Routing** : Gateway API HTTPRoute avec TLS via cert-manager
- **Securite** : PSA restricted profile, network policies (Cilium/Calico), Kyverno PolicyException scopee

## Architecture

```
                    ┌─────────────────────┐
                    │   Gateway (Envoy)   │
                    │  SecurityPolicy     │◄── OIDC (web UI)
                    │  (OAuth2/OIDC)      │
                    └────────┬────────────┘
                             │ HTTPRoute
                    ┌────────▼────────────┐
                    │   Harbor Portal     │
                    │   (Web UI)          │
                    └────────┬────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼──┐   ┌──────▼────┐   ┌─────▼─────┐
     │  Harbor   │   │  Harbor   │   │  Harbor   │
     │  Core     │   │  Registry │   │  Trivy    │
     └─────┬─────┘   └─────┬─────┘   │  (Scan)   │
           │               │         └───────────┘
     ┌─────▼──────┐  ┌─────▼─────┐
     │ PostgreSQL │  │   PVC     │
     │  (CNPG)    │  │ (Registry)│
     └────────────┘  └───────────┘
```

## Feature Flags

| Flag | Description |
|------|-------------|
| `features.registry.enabled` | Active le deploiement de Harbor |
| `features.registry.provider` | Provider (`harbor`) |
| `features.storage.provider` | `rook` → active le PreSync hook Ceph |
| `features.monitoring.enabled` | ServiceMonitor + PrometheusRules |
| `features.sso.enabled` + `provider: keycloak` | OIDC client Keycloak + config Harbor |
| `features.gatewayAPI.httpRoute.enabled` | HTTPRoute Gateway API |
| `features.oauth2Proxy.enabled` | SecurityPolicy OIDC (Envoy Gateway) ou AuthorizationPolicy (Istio) |
| `features.networkPolicy.*` | Network policies Cilium/Calico |
| `features.kyverno.enabled` | PolicyException pour le Job PreSync |
| `rke2.cis.enabled` | Namespace avec PSA restricted |

## Configuration

### Dev vs Prod

| Parametre | Dev | Prod |
|-----------|-----|------|
| Chart version | 1.18.2 | 1.18.2 |
| Replicas (portal, core, jobservice, registry) | 1 | 2 |
| Replicas Trivy | 1 | 1 |
| Registry PVC | 10Gi | 50Gi |
| Redis PVC | 1Gi | 5Gi |
| Trivy PVC | 5Gi | 10Gi |
| JobService PVC | 1Gi | 5Gi |
| CNPG instances | 1 | 3 (HA) |
| CNPG storage | 2Gi | 10Gi |
| Internal TLS | false | true |
| Auto-sync | true | false |

### Fichiers de configuration

- `config/dev.yaml` : Configuration de developpement (single instance)
- `config/prod.yaml` : Configuration de production (HA)

## Secrets (SOPS/KSOPS)

Les secrets sont geres via SOPS avec chiffrement AGE. Chaque environnement a sa propre structure :

```
secrets/{dev,prod}/
├── kustomization.yaml     # generators: ksops-generator.yaml
├── ksops-generator.yaml   # viaduct.ai/v1 ksops → secret.yaml
└── secret.yaml            # Multi-document YAML (chiffre SOPS)
```

Le fichier `secret.yaml` contient **trois Secrets** (multi-document YAML) :

1. **`harbor-admin-credentials`** (namespace `harbor`) :
   - `HARBOR_ADMIN_PASSWORD` : Mot de passe admin Harbor
   - `HARBOR_OIDC_CLIENT_SECRET` : Secret OIDC pour la config Harbor
2. **`harbor-oidc-credentials`** (namespace `keycloak`) :
   - `HARBOR_OIDC_CLIENT_SECRET` : Meme secret OIDC pour la creation du client Keycloak
3. **`harbor-db-credentials`** (namespace `harbor`, sync-wave `-2`) :
   - `username` : Utilisateur PostgreSQL CNPG (`harbor`)
   - `password` : Mot de passe PostgreSQL CNPG

Cette approche multi-document permet de partager le secret OIDC entre les namespaces `harbor` et `keycloak` depuis une source unique chiffree. Le secret DB est deploye en sync-wave `-2` pour etre disponible avant la creation du cluster CNPG (sync-wave `-1`).

### Commandes SOPS

```bash
cd deploy/argocd

# Chiffrer (OBLIGATOIRE avant commit)
sops encrypt --in-place apps/harbor/secrets/dev/secret.yaml

# Editer
sops apps/harbor/secrets/dev/secret.yaml

# Voir en clair
sops decrypt apps/harbor/secrets/dev/secret.yaml
```

## SSO / OIDC

L'authentification OIDC est configuree en deux couches :

### Couche 1 : Envoy Gateway SecurityPolicy (Web UI)

Quand `features.oauth2Proxy.enabled` et `gatewayAPI.controller.provider = envoy-gateway` :

- `SecurityPolicy` avec OIDC (provider Keycloak, redirect `/oauth2/callback`)
- `Backend` pointant vers `keycloak.<domain>` (FQDN)
- `ExternalSecret` pour le certificat CA du cluster
- `oidc-secret` pour le client secret

### Couche 2 : Harbor OIDC natif (Docker CLI + Web fallback)

Deux Jobs PostSync deployes via `kustomize/sso/` :

1. **`harbor-keycloak-oidc-client`** (namespace `keycloak`) :
   - Attend que Keycloak et le realm `k8s` soient prets
   - Cree/met a jour le client OIDC `harbor` avec le secret explicite
   - Redirect URIs : `/c/oidc/callback` et `/oauth2/callback`
   - Protocol mappers : `groups` (pour le mapping admin Harbor)

2. **`harbor-oidc-config`** (namespace `harbor`) :
   - Attend que Harbor soit pret
   - Configure Harbor en mode `oidc_auth` via l'API `/api/v2.0/configurations`
   - Parametres : endpoint Keycloak, group claim `groups`, admin group `harbor-admins`, auto-onboard

### PostSync Hooks

Les deux Jobs utilisent les bonnes pratiques :
- `hook-delete-policy: BeforeHookCreation,HookSucceeded` (idempotence)
- `backoffLimit: 5` avec `restartPolicy: OnFailure`
- Resources requests/limits : `cpu: 5m-50m`, `memory: 32Mi-64Mi`
- SecurityContext : `runAsNonRoot`, `readOnlyRootFilesystem`, drop `ALL` capabilities

## Base de donnees PostgreSQL (CNPG)

Harbor utilise un cluster PostgreSQL externe gere par CloudNativePG (CNPG). Ce pattern est identique a celui de Keycloak.

### Architecture

- **Cluster CNPG** : `harbor-db` (namespace `harbor`)
- **Service RW** : `harbor-db-rw.harbor.svc:5432` (endpoint read-write)
- **Base de donnees** : `registry` (owner: `harbor`)
- **Credentials** : Secret `harbor-db-credentials` (gere via SOPS)

### Sync Waves

1. **Wave -2** : Secret `harbor-db-credentials` (SOPS)
2. **Wave -1** : Cluster CNPG `harbor-db`
3. **Wave 0** : Chart Helm Harbor (utilise la DB externe)

### PreSync/Sync Hooks

1. **PreSync** : `harbor-cnpg-webhook-presync-check` - Attend que le webhook CNPG soit operationnel
2. **Sync** : `db-readiness-check` - Attend que le cluster CNPG soit healthy et le service `harbor-db-rw` ait des endpoints

## Stockage et PreSync Hook

### Ceph PreSync Check

Quand `features.storage.provider = rook`, un Job PreSync attend que le stockage Ceph soit pret avant que Harbor cree ses PVCs :

1. Verifie que le namespace `rook-ceph` existe
2. Attend que `CephCluster` soit `Ready`
3. Attend que `CephBlockPool` soit `Ready`

Le Job a ses propres RBAC (ServiceAccount + ClusterRole + ClusterRoleBinding) car il utilise `kubectl` pour interroger les CRDs Ceph.

### Protection PVC

Les PVCs Harbor sont protegees contre la suppression accidentelle :
```yaml
annotations:
  argocd.argoproj.io/sync-options: Prune=false
```

PVCs : `registry`, `jobservice`, `redis`, `trivy`.

## Monitoring

### ServiceMonitor

Active quand `features.monitoring.enabled: true`. Le chart Helm Harbor cree automatiquement un ServiceMonitor avec le label `release: prometheus-stack`.

### PrometheusRules

Alertes deployees via `kustomize/monitoring/` :

| Alerte | Severite | Condition |
|--------|----------|-----------|
| `HarborCoreDown` | critical | Aucun pod Core disponible pendant 5m |
| `HarborCorePodRestarting` | high | Pod Core en restart pendant 10m |
| `HarborRegistryDown` | critical | Aucun pod Registry disponible pendant 5m |
| `HarborRegistryStorageHigh` | warning | Stockage registry < 20% disponible |
| `HarborDatabaseDown` | critical | Cluster CNPG `harbor-db` injoignable pendant 5m |
| `HarborDatabaseHighReplicationLag` | warning | Lag de replication CNPG > 30s pendant 5m |
| `HarborDatabaseStorageLow` | warning | Stockage CNPG database < 20% disponible |
| `HarborTrivyDown` | warning | Scanner Trivy indisponible pendant 10m |

### PodMonitor CNPG

Un `PodMonitor` (`harbor-postgresql`) collecte les metriques de l'exporter CNPG sur le port `metrics`.

## Network Policies

### Pod Ingress (defaultDenyPodIngress)

Deploiement conditionnel selon le CNI :
- **Cilium** : `CiliumNetworkPolicy` dans `resources/cilium-ingress-policy.yaml`
- **Calico** : `NetworkPolicy` dans `resources/calico-ingress-policy.yaml`

### Host Ingress (ingressPolicy)

Policies specifiques au provider Gateway API (7 variantes par CNI) :
- `cilium-ingress-policy-{envoy-gateway,istio,apisix,traefik,nginx-gwf,cilium}.yaml`
- `calico-ingress-policy-{envoy-gateway,istio,apisix,traefik,nginx-gwf,cilium}.yaml`

## Routing (Gateway API)

### HTTPRoute

Active quand `features.gatewayAPI.httpRoute.enabled: true`.

Route `harbor.<domain>` vers le service ClusterIP Harbor (port 80) avec TLS via cert-manager (`selfsigned-cluster-issuer`).

### ReferenceGrant

Autorise le Gateway (dans son namespace) a referencer le service Harbor dans le namespace `harbor`.

## Kyverno PolicyException

Active quand `features.kyverno.enabled: true`.

Exception scopee aux Jobs PreSync/Sync qui utilisent `kubectl` :
- `harbor-ceph-storage-check*` : PreSync Ceph storage
- `harbor-cnpg-webhook-presync*` : PreSync CNPG webhook
- `db-readiness*` : Sync DB readiness check

Le chart Helm Harbor definit deja `automountServiceAccountToken: false` sur tous ses composants, donc seuls ces Jobs ont besoin de cette exception.

## Structure des fichiers

```
harbor/
├── applicationset.yaml                          # ApplicationSet principal
├── README.md                                    # Cette documentation
├── config/
│   ├── dev.yaml                                 # Config dev (1 replica, 10Gi)
│   └── prod.yaml                                # Config prod (2 replicas, 50Gi)
├── resources/
│   ├── namespace.yaml                           # Namespace PSA restricted
│   ├── cluster-postgresql.yaml                  # Cluster CNPG PostgreSQL (sync-wave -1)
│   ├── cnpg-webhook-presync-check.yaml          # PreSync: attente webhook CNPG
│   ├── db-readiness-check.yaml                  # Sync: attente DB ready
│   ├── ceph-storage-presync-check.yaml          # PreSync: attente Ceph (SA+RBAC+Job)
│   ├── kyverno-policy-exception.yaml            # PolicyException PreSync/Sync Jobs
│   ├── cilium-ingress-policy.yaml               # CiliumNetworkPolicy (pod ingress)
│   ├── cilium-ingress-policy-*.yaml             # 6 variantes par provider Gateway
│   ├── calico-ingress-policy.yaml               # NetworkPolicy Calico (pod ingress)
│   └── calico-ingress-policy-*.yaml             # 6 variantes par provider Gateway
├── kustomize/
│   ├── httproute/                               # HTTPRoute + ReferenceGrant
│   │   ├── kustomization.yaml
│   │   ├── httproute.yaml
│   │   └── referencegrant.yaml
│   ├── httproute-oauth2-envoy-gateway/          # HTTPRoute + SecurityPolicy OIDC
│   │   ├── kustomization.yaml
│   │   ├── backend-keycloak.yaml
│   │   ├── external-secret-ca.yaml
│   │   ├── oidc-secret.yaml
│   │   └── security-policy.yaml
│   ├── monitoring/                              # PrometheusRules + PodMonitor CNPG
│   │   ├── kustomization.yaml
│   │   └── prometheusrules.yaml
│   ├── oauth2-authz/                            # Istio AuthorizationPolicy
│   │   ├── kustomization.yaml
│   │   └── authorization-policy.yaml
│   └── sso/                                     # Keycloak OIDC Jobs
│       ├── kustomization.yaml
│       ├── keycloak-oidc-client.yaml            # PostSync: creation client Keycloak
│       └── harbor-oidc-config.yaml              # PostSync: config OIDC Harbor
└── secrets/
    ├── dev/                                     # Secrets dev (SOPS)
    │   ├── kustomization.yaml
    │   ├── ksops-generator.yaml
    │   └── secret.yaml
    └── prod/                                    # Secrets prod (SOPS)
        ├── kustomization.yaml
        ├── ksops-generator.yaml
        └── secret.yaml
```

## Deploiement

### Prerequis

1. **CNPG** : Operateur CloudNativePG deploye (pour PostgreSQL)
2. **Stockage** : Rook/Ceph ou Longhorn deploye et pret
3. **Monitoring** : prometheus-stack deploye (pour ServiceMonitor)
4. **Gateway API** : Controller Gateway API deploye (pour HTTPRoute)
5. **Keycloak** : Keycloak deploye avec realm `k8s` (pour SSO)
6. **Secrets** : Fichiers SOPS chiffres dans `secrets/dev/` et `secrets/prod/`

### Activation

1. Dans `config/config.yaml` :
```yaml
features:
  registry:
    enabled: true
    provider: "harbor"
```

2. Deployer :
```bash
make argocd-install-dev  # Inclut deploy-applicationsets.sh
```

## Depannage

### Harbor ne demarre pas

```bash
# Verifier l'Application ArgoCD
kubectl get application -n argo-cd harbor -o yaml

# Verifier les pods
kubectl get pods -n harbor

# Verifier les PVCs
kubectl get pvc -n harbor
```

### PVCs en Pending

Le PreSync hook devrait prevenir ce probleme. Si les PVCs sont en Pending :

```bash
# Verifier le storage
kubectl get cephcluster -n rook-ceph
kubectl get cephblockpool -n rook-ceph
kubectl get sc

# Verifier le Job PreSync
kubectl get jobs -n harbor | grep ceph
kubectl logs -n harbor job/harbor-ceph-storage-check
```

### SSO/OIDC ne fonctionne pas

```bash
# Verifier les Jobs PostSync
kubectl get jobs -n keycloak | grep harbor
kubectl logs -n keycloak job/harbor-keycloak-oidc-client
kubectl get jobs -n harbor | grep oidc
kubectl logs -n harbor job/harbor-oidc-config

# Verifier le client Keycloak
# Via l'interface admin Keycloak : Clients > harbor > Settings

# Verifier la config Harbor
kubectl exec -it deploy/harbor-core -n harbor -- \
  curl -s http://localhost:8080/api/v2.0/configurations \
  -u "admin:<password>" | jq '.auth_mode, .oidc_endpoint'
```

### Base de donnees CNPG

```bash
# Verifier le cluster CNPG
kubectl get cluster harbor-db -n harbor

# Verifier le statut detaille
kubectl describe cluster harbor-db -n harbor

# Verifier les pods CNPG
kubectl get pods -n harbor -l app.kubernetes.io/instance=harbor-db

# Logs du pod PostgreSQL
kubectl logs -n harbor harbor-db-1 -c postgres

# Verifier le service RW
kubectl get endpoints harbor-db-rw -n harbor

# Verifier les Jobs presync/sync
kubectl get jobs -n harbor | grep -E "cnpg-webhook|db-readiness"
kubectl logs -n harbor job/harbor-cnpg-webhook-presync-check
kubectl logs -n harbor job/db-readiness-check
```

### Docker push/pull echoue

```bash
# Tester la connectivite
curl -sk https://harbor.<domain>/api/v2.0/health

# Login Docker
docker login harbor.<domain>

# Si erreur TLS, verifier le certificat
openssl s_client -connect harbor.<domain>:443 -servername harbor.<domain>
```

### Alertes Prometheus

```bash
# Verifier les alertes actives
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Visiter http://localhost:9090/alerts et chercher "Harbor"

# Verifier les metriques
# harbor_up, harbor_project_total, harbor_registry_storage_total_bytes
```

## References

- [Harbor Documentation](https://goharbor.io/docs/)
- [Harbor Helm Chart](https://github.com/goharbor/harbor-helm)
- [Harbor OIDC Configuration](https://goharbor.io/docs/latest/administration/configure-authentication/oidc-auth/)
- [Harbor API v2.0](https://editor.swagger.io/?url=https://raw.githubusercontent.com/goharbor/harbor/main/api/v2.0/swagger.yaml)
- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
