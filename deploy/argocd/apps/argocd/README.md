# ArgoCD - Declarative GitOps CD for Kubernetes

ArgoCD est un outil de déploiement continu (CD) déclaratif qui suit le paradigme GitOps. Il surveille les repositories Git et synchronise automatiquement l'état du cluster Kubernetes avec les manifestes Git.

## Vue d'Ensemble

**Deployment**: ArgoCD self-managed (ArgoCD déploie et gère lui-même via ApplicationSet)
**Wave**: 50 (après ingress, avant storage)
**Chart**: [argo-helm/argo-cd](https://github.com/argoproj/argo-helm)
**Namespace**: `argo-cd`

## Dépendances

### Requises
- **Kubernetes 1.21+**
- **CustomResourceDefinitions (CRDs)**: Installées automatiquement par le chart

### Optionnelles
- **Ingress-NGINX** (Wave 40): Pour accès UI/CLI via ingress
- **Cert-Manager** (Wave 20): Pour TLS automatique sur l'ingress
- **Prometheus Stack** (Wave 75): Pour monitoring et alerting
- **External-DNS** (Wave 45): Pour DNS automatique

## Architecture

### Composants ArgoCD

**Application Controller**:
- Surveille les Applications et synchronise l'état désiré (Git) avec l'état actuel (cluster)
- Gère la réconciliation et le health checking
- **Dev**: 1 replica (200m CPU, 512Mi RAM)
- **Prod**: 3 replicas (200m CPU, 1Gi RAM) pour HA

**Repo Server**:
- Clone les repositories Git et génère les manifestes Kubernetes
- Supporte Helm, Kustomize, Jsonnet, plain YAML
- **Dev**: 1 replica (100m CPU, 128Mi RAM)
- **Prod**: 3 replicas (200m CPU, 256Mi RAM) pour HA

**API Server**:
- Expose l'API gRPC/REST pour UI, CLI, et webhooks
- Gère l'authentification et l'autorisation
- **Dev**: 1 replica (100m CPU, 128Mi RAM)
- **Prod**: 3 replicas (200m CPU, 256Mi RAM) pour HA

**ApplicationSet Controller**:
- Génère automatiquement les Applications ArgoCD à partir de templates
- Supporte les generators (Git, List, Cluster, Matrix, Merge)
- Utilisé pour déployer toutes les apps de cette infrastructure

**Notifications Controller**:
- Envoie des notifications (Slack, Email, etc.) sur les événements ArgoCD
- Triggers configurables (sync success/failure, health degraded, etc.)

**Redis**:
- Cache pour améliorer les performances
- **Dev**: Redis standalone (50m CPU, 64Mi RAM)
- **Prod**: Redis HA avec HAProxy (3 replicas)

**Dex** (optionnel):
- Service d'authentification SSO/OIDC
- Désactivé par défaut (peut être activé via config)

### Self-Managed Pattern

ArgoCD se déploie et se gère lui-même via une ApplicationSet:
1. **Bootstrap**: Déploiement initial via `kubectl apply` du root Application
2. **ApplicationSet**: Génère l'Application ArgoCD qui se déploie dans `argo-cd`
3. **Auto-sync**: ArgoCD surveille son propre ApplicationSet et se met à jour

**Attention**: Les changements au ApplicationSet ArgoCD nécessitent une attention particulière car une erreur peut rendre ArgoCD inopérant.

## Configuration

### Dev (config-dev.yaml)

```yaml
argocd:
  server:
    ingress:
      enabled: true
      # hostname: argocd.k8s.lan (géré par ApplicationSet)
    replicas: 1
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits: {cpu: 200m, memory: 256Mi}

  controller:
    replicas: 1
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits: {cpu: 500m, memory: 1Gi}

  repoServer:
    replicas: 1
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits: {cpu: 200m, memory: 256Mi}

  redis:
    ha: false  # Redis standalone

  dex:
    enabled: false  # SSO désactivé

syncPolicy:
  automated:
    enabled: true
    prune: true
    selfHeal: true
```

### Prod (config-prod.yaml)

```yaml
argocd:
  server:
    replicas: 3  # HA
    resources:
      requests: {cpu: 200m, memory: 256Mi}
      limits: {cpu: 500m, memory: 512Mi}

  controller:
    replicas: 3  # HA
    resources:
      requests: {cpu: 200m, memory: 1Gi}
      limits: {cpu: 1000m, memory: 2Gi}

  repoServer:
    replicas: 3  # HA
    resources:
      requests: {cpu: 200m, memory: 256Mi}
      limits: {cpu: 500m, memory: 512Mi}

  redis:
    ha: true  # Redis HA avec HAProxy

  dex:
    enabled: false  # SSO peut être activé

syncPolicy:
  automated:
    enabled: false  # Sync manuel en prod
    prune: true
    selfHeal: true
```

## Accès ArgoCD

### UI Web

**Dev**:
```bash
# URL (avec ingress-nginx + external-dns)
https://argocd.k8s.lan

# Ou port-forward
kubectl port-forward -n argo-cd svc/argocd-server 8080:443
# Puis: https://localhost:8080
```

**Prod**:
```bash
# URL (avec ingress-nginx + external-dns)
https://argocd.k8s.lan  # ou votre domaine prod

# Accepter le certificat self-signed en dev
# En prod, utiliser Let's Encrypt via cert-manager
```

### Admin Password

**Récupérer le password initial**:
```bash
kubectl -n argo-cd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

**Changer le password** (via UI ou CLI):
```bash
argocd account update-password
```

**Supprimer le secret initial** (après avoir changé le password):
```bash
kubectl -n argo-cd delete secret argocd-initial-admin-secret
```

### CLI

**Installation**:
```bash
# Linux
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# macOS
brew install argocd
```

**Login**:
```bash
# Via ingress
argocd login argocd.k8s.lan --grpc-web

# Via port-forward
argocd login localhost:8080 --insecure
```

**Commandes utiles**:
```bash
# Lister les applications
argocd app list

# Voir le statut d'une app
argocd app get metallb

# Synchroniser une app
argocd app sync metallb

# Voir les logs
argocd app logs metallb

# Créer une app
argocd app create my-app --repo https://github.com/user/repo \
  --path manifests --dest-server https://kubernetes.default.svc \
  --dest-namespace default

# Supprimer une app
argocd app delete my-app
```

## Monitoring

### Prometheus Metrics

**ServiceMonitors** (créés automatiquement par le chart):
- `argocd-server` (API server metrics)
- `argocd-controller` (Application controller metrics)
- `argocd-repo-server` (Repo server metrics)
- `argocd-applicationset` (ApplicationSet controller metrics)
- `argocd-notifications` (Notifications controller metrics)
- `argocd-redis` (Redis metrics)
- `argocd-dex` (Dex metrics, si activé)

**Métriques clés**:
```promql
# Applications
argocd_app_info                              # Info sur les apps
argocd_app_sync_total                        # Sync count
argocd_app_reconcile_count                   # Reconcile count
argocd_app_reconcile_duration_seconds        # Reconcile duration

# Controller
argocd_app_k8s_request_total                 # K8s API requests
argocd_cluster_api_resource_objects          # Resource objects count
argocd_cluster_events_total                  # Cluster events

# Repo Server
argocd_git_request_total                     # Git requests
argocd_git_request_duration_seconds          # Git request duration

# Server
argocd_redis_request_total                   # Redis requests
grpc_server_handled_total                    # gRPC requests
```

### PrometheusRule Alerts

**14 alertes configurées** (`prometheus.yaml`):

**Critiques**:
- `ArgoCDAppMissing`: Aucune app détectée (15m)
- `ArgoCDControllerUnhealthy`: Controller down (5m)
- `ArgoCDRepoServerUnhealthy`: Repo server down (5m)
- `ArgoCDAPIServerUnhealthy`: API server down (5m)
- `ArgoCDRegistryErrors`: Augmentation des erreurs registry (15m, >5)

**Warnings**:
- `ArgoCDAppNotSynced`: App pas sync depuis 12h
- `ArgoCDAppHealthyIssue`: App unhealthy (10m)
- `ArgoCDRepoConnectionError`: Erreur connexion Git (5m)
- `ArgoCDAppSyncFailed`: Sync failed (5m)
- `ArgoCDAppOutOfSync`: Out of sync (15m)
- `ArgoCDHighQueueDepth`: Queue depth élevée (>100, 15m)
- `ArgoCDHighReconcileTime`: Reconcile lent (>300s, 10m)
- `ArgoCDGitOperationErrors`: Erreurs Git (rate >0.1, 10m)
- `ArgoCDRedisDown`: Redis down (5m)

### Grafana Dashboard

**Dashboard ArgoCD** (`grafana-dashboard.yaml`):
- **gnetId**: 14584 (dashboard officiel)
- **Auto-import**: Via ConfigMap avec label `grafana_dashboard: "1"`
- **Sections**:
  - Applications count
  - Application health status (timeline)
  - Apps out of sync
  - Sync stats and activity
  - Controller stats (reconciliation, K8s API)
  - Controller telemetry (CPU, memory, goroutines)
  - Cluster stats (resources, events)
  - Repo server stats (Git requests, performance)
  - Server stats (gRPC services)
  - Redis stats

**Variables**:
- `datasource`: Prometheus
- `namespace`: argo-cd
- `sync_status`: Filter par sync status
- `health_status`: Filter par health status

## Troubleshooting

### Apps ne se synchronisent pas

**Symptôme**: Applications restent "OutOfSync"

**Vérifications**:
```bash
# Status de l'app
argocd app get <app-name>

# Diff entre Git et cluster
argocd app diff <app-name>

# Logs controller
kubectl logs -n argo-cd deployment/argocd-application-controller

# Sync manuel
argocd app sync <app-name>
```

**Causes courantes**:
- **Auto-sync désactivé**: Vérifier syncPolicy.automated.enabled
- **Erreur Git**: Credentials manquants, branch inexistante
- **Erreur manifestes**: YAML invalide, CRDs manquantes
- **Sync hooks**: Hooks qui échouent (PreSync, Sync, PostSync)

### Applications en état "Progressing"

**Symptôme**: App reste "Progressing" indéfiniment

**Vérifications**:
```bash
# Voir les ressources de l'app
kubectl get all -n <namespace>

# Health check de l'app
argocd app get <app-name> --show-operation

# Pods status
kubectl get pods -n <namespace>
```

**Causes courantes**:
- **Pods CrashLoopBackOff**: Erreur dans l'image ou config
- **Readiness probe fail**: Probe mal configuré
- **PVC Pending**: Storage class manquant
- **ImagePullBackOff**: Image inexistante ou credentials manquants

### Erreurs de connexion Git

**Symptôme**: "failed to get git client"

**Vérifications**:
```bash
# Vérifier repository credentials
kubectl get secrets -n argo-cd | grep repo

# Logs repo server
kubectl logs -n argo-cd deployment/argocd-repo-server

# Tester accès Git manuellement
argocd repo list
argocd repo get https://github.com/user/repo
```

**Solutions**:
- **Repository privé**: Ajouter credentials (SSH key ou token)
- **Proxy/firewall**: Vérifier accès réseau depuis le cluster
- **Branch/tag invalide**: Vérifier targetRevision dans ApplicationSet

### ArgoCD UI inaccessible

**Symptôme**: Cannot access https://argocd.k8s.lan

**Vérifications**:
```bash
# Service ArgoCD
kubectl get svc -n argo-cd argocd-server

# Ingress
kubectl get ingress -n argo-cd

# Certificat TLS
kubectl get certificate -n argo-cd

# Logs ingress-nginx
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

**Solutions**:
- **Ingress disabled**: Activer `server.ingress.enabled: true`
- **DNS not resolving**: Vérifier external-dns
- **TLS error**: Vérifier cert-manager et ClusterIssuer
- **Port-forward alternatif**: `kubectl port-forward -n argo-cd svc/argocd-server 8080:443`

### Redis connection errors

**Symptôme**: "Failed to connect to Redis"

**Vérifications**:
```bash
# Redis pods
kubectl get pods -n argo-cd | grep redis

# Redis logs
kubectl logs -n argo-cd deployment/argocd-redis

# Redis HA (si activé)
kubectl get pods -n argo-cd | grep redis-ha
```

**Solutions**:
- **Redis down**: Restart pod ou vérifier resources
- **HA not configured**: Activer `redis.ha: true` en prod
- **Network policy**: Vérifier policies réseau

### Self-managed ArgoCD broken

**Symptôme**: ArgoCD ApplicationSet/Application cassé, ArgoCD ne fonctionne plus

**DANGER**: Modifications au self-managed ArgoCD peuvent le rendre inopérant!

**Recovery**:
```bash
# Option 1: Rollback Git
git revert <bad-commit>
git push
# Attendre auto-sync (si encore fonctionnel)

# Option 2: Re-bootstrap
cd argocd
make bootstrap

# Option 3: Reinstall (DESTRUCTIF!)
kubectl delete -f bootstrap/root.yaml
kubectl delete namespace argo-cd
# Puis: make bootstrap
```

**Prévention**:
- Tester les changements en dev d'abord
- Ne jamais push directement en prod sans validation
- Garder un backup de la config ArgoCD
- Sync manuel en prod (automated.enabled: false)

## Configuration Avancée

### Dex/SSO (OIDC)

**Activer Dex** (config-prod.yaml):
```yaml
argocd:
  dex:
    enabled: true
    config: |
      connectors:
        - type: github
          id: github
          name: GitHub
          config:
            clientID: $GITHUB_CLIENT_ID
            clientSecret: $GITHUB_CLIENT_SECRET
            orgs:
              - name: my-org
```

**Créer les secrets**:
```bash
kubectl create secret generic github-dex-config \
  --from-literal=client-id=YOUR_CLIENT_ID \
  --from-literal=client-secret=YOUR_CLIENT_SECRET \
  -n argo-cd
```

### Redis HA

**Activer Redis HA** (config-prod.yaml):
```yaml
argocd:
  redis:
    ha: true  # 3 replicas Redis + HAProxy
```

### Notifications

**Configurer Slack**:
```yaml
# Dans server.config
notifications:
  triggers:
    - name: on-sync-succeeded
      template: sync-succeeded
      enabled: true
  templates:
    - name: sync-succeeded
      slack:
        attachments: |
          [{
            "title": "{{.app.metadata.name}}",
            "color": "good",
            "fields": [{
              "title": "Sync Status",
              "value": "{{.app.status.sync.status}}",
              "short": true
            }]
          }]
  services:
    slack:
      token: $SLACK_TOKEN
```

### RBAC Policies

**Exemple RBAC**:
```yaml
argocd:
  server:
    rbacConfig:
      policy.default: role:readonly
      policy.csv: |
        p, role:org-admin, applications, *, */*, allow
        p, role:org-admin, clusters, get, *, allow
        p, role:org-admin, repositories, *, *, allow
        g, my-org:team-admins, role:org-admin
```

## Docs

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [ApplicationSets](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [Sync Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [Health Assessment](https://argo-cd.readthedocs.io/en/stable/operator-manual/health/)
- [RBAC Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Metrics](https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/)
