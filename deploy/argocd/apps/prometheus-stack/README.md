# Prometheus Stack - Complete Monitoring Solution

Kube-Prometheus-Stack est une collection complète d'outils de monitoring pour Kubernetes incluant Prometheus, Grafana, Alertmanager et divers exporters.

## Vue d'Ensemble

**Deployment**: Helm chart (kube-prometheus-stack)
**Wave**: 75 (après storage, nécessite persistence)
**Chart**: [prometheus-community/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
**Namespace**: `monitoring`

## Composants

### Prometheus

**Rôle**: Collecte et stocke les métriques time-series

**Fonctionnalités**:
- Scraping automatique via ServiceMonitors
- Stockage time-series avec retention configurable
- PromQL query language
- Remote write/read support
- Federation support

**Accès**: https://prometheus.gigix

### Grafana

**Rôle**: Visualisation et dashboards

**Fonctionnalités**:
- Dashboards pré-configurés (Kubernetes, nodes, pods, etc.)
- Auto-import des ConfigMaps avec label `grafana_dashboard: "1"`
- Sidecar pour découverte automatique des dashboards
- Multi-datasource support
- Alerting UI
- **OIDC Authentication** (Keycloak) avec auto-login

**Accès**: https://grafana.gigix
**Authentification**: OIDC via Keycloak (auto-login activé)

### Alertmanager

**Rôle**: Gestion et routing des alertes

**Fonctionnalités**:
- Grouping, throttling, silencing
- Routing vers receivers (Slack, Email, PagerDuty, etc.)
- High Availability avec clustering

**Accès**: https://alertmanager.gigix (prod uniquement)

### Exporters

**Node Exporter**:
- Métriques système des nodes (CPU, RAM, disk, network)
- DaemonSet sur tous les nodes

**Kube-State-Metrics**:
- Métriques Kubernetes (deployments, pods, services, etc.)
- Object status and health

**Prometheus Operator**:
- Gère les CRDs Prometheus (ServiceMonitor, PrometheusRule, etc.)
- Automatic scrape config generation

## Dépendances

### Requises
- **Kubernetes 1.19+**
- **Longhorn** (Wave 60): Pour persistence Prometheus/Grafana (prod)

### Optionnelles
- **Ingress-NGINX** (Wave 40): Pour accès UI via ingress
- **Cert-Manager** (Wave 20): Pour TLS automatique
- **External-DNS** (Wave 30): Pour DNS automatique

## Configuration

### Dev (config-dev.yaml)

```yaml
prometheusStack:
  prometheus:
    replicas: 1
    retention: "2d"  # Courte retention
    storage: "2Gi"   # Petit stockage
    resources:
      requests: {cpu: 100m, memory: 512Mi}
      limits: {cpu: 500m, memory: 1Gi}
    ingress:
      enabled: true
      hostname: "prometheus.gigix"

  grafana:
    replicas: 1
    persistence:
      enabled: false  # Pas de persistence en dev
    resources:
      requests: {cpu: 50m, memory: 128Mi}
      limits: {cpu: 200m, memory: 256Mi}
    ingress:
      enabled: true
      hostname: "grafana.gigix"

  alertmanager:
    enabled: false  # Disabled en dev
```

### Prod (config-prod.yaml)

```yaml
prometheusStack:
  prometheus:
    replicas: 2  # HA
    retention: "7d"
    storage: "5Gi"
    resources:
      requests: {cpu: 200m, memory: 1Gi}
      limits: {cpu: 1000m, memory: 2Gi}
    ingress:
      enabled: true
      hostname: "prometheus.gigix"

  grafana:
    replicas: 2  # HA
    persistence:
      enabled: true
      size: "10Gi"
      storageClass: "longhorn"
    resources:
      requests: {cpu: 100m, memory: 256Mi}
      limits: {cpu: 500m, memory: 512Mi}
    ingress:
      enabled: true
      hostname: "grafana.gigix"

  alertmanager:
    enabled: true
    replicas: 3  # HA avec clustering
    ingress:
      enabled: true
      hostname: "alertmanager.gigix"
```

## Accès

### Grafana

**URL**: https://grafana.gigix

**Authentification OIDC (Keycloak)**:

L'accès web utilise l'authentification OIDC avec auto-login:
1. Naviguer vers https://grafana.gigix
2. Redirection automatique vers Keycloak
3. S'authentifier avec votre compte Keycloak
4. Retour automatique vers Grafana

**Rôles Grafana** (basés sur les groupes Keycloak):
| Groupe Keycloak | Rôle Grafana |
|-----------------|--------------|
| `admins` | Admin (accès complet) |
| `developers` | Editor (dashboards, alertes) |
| Autres | Viewer (lecture seule) |

**Logout**: Déconnexion complète via Keycloak (SSO)

**Admin local** (fallback):
```bash
# Récupérer le password admin local
kubectl get secret -n monitoring prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

**Note**: Le compte admin local est géré via KSOPS (secrets chiffrés).
Utiliser l'authentification OIDC pour l'accès normal.

### Prometheus

**URL**: https://prometheus.gigix

**Query examples**:
```promql
# CPU usage
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# Pod CPU
rate(container_cpu_usage_seconds_total{pod="my-pod"}[5m])

# Disk usage
node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100
```

### Alertmanager (Prod)

**URL**: https://alertmanager.gigix

**Silencing alerts**:
1. Aller dans "Silences"
2. "New Silence"
3. Matchers: `alertname="MyAlert"`
4. Duration, Creator, Comment
5. Create

## Dashboards Grafana

### Dashboards Pré-Installés

Le chart installe automatiquement ~20 dashboards:

**Kubernetes**:
- Kubernetes / API Server
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace
- Kubernetes / Compute Resources / Pod
- Kubernetes / Networking / Cluster
- Kubernetes / Networking / Namespace
- Kubernetes / Networking / Pod

**Nodes**:
- Node Exporter / Nodes (Linux)
- Node Exporter / USE Method / Node

**Note**: Les dashboards Node Exporter pour macOS (Darwin) et AIX sont désactivés dans l'ApplicationSet car ce cluster utilise uniquement des nodes Linux (Ubuntu). Ils peuvent être réactivés via les paramètres Helm `nodeExporter.operatingSystems.darwin.enabled` et `nodeExporter.operatingSystems.aix.enabled`.

**Prometheus**:
- Prometheus / Overview
- Prometheus / Remote Write

**Alertmanager**:
- Alertmanager / Overview

**Note sur kube-proxy**:
Le dashboard "Kubernetes / Proxy" et le ServiceMonitor kube-proxy sont désactivés (`kubeProxy.enabled: false`) car kube-proxy n'est pas installé dans ce cluster. Cilium est configuré avec `kubeProxyReplacement: true` et remplace complètement kube-proxy en utilisant eBPF pour gérer les services Kubernetes. Les métriques équivalentes sont disponibles dans les dashboards Cilium.

### Dashboards Auto-Import

Les dashboards des autres apps sont auto-importés via sidecar:

**ConfigMaps avec label `grafana_dashboard: "1"`**:
- Cert-Manager (ID: cert-manager-dashboard.json)
- ArgoCD (ID: argocd-dashboard.json)
- Ingress-NGINX (ID 9614, à importer manuellement)
- Longhorn (ID 13032, à importer manuellement)

**Configuration sidecar** (automatique):
```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      folderAnnotation: grafana_folder
      foldersFromFilesStructure: true
```

### Importer un Dashboard Externe

**Via UI**:
1. Grafana → Dashboards → Import
2. Enter dashboard ID (ex: 9614 pour NGINX)
3. Select Prometheus datasource
4. Import

**Via ConfigMap** (auto-import):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |-
    {dashboard JSON...}
```

## Alerting

### PrometheusRules

Chaque app peut définir ses alertes via PrometheusRule:

**Exemple** (cert-manager/prometheus.yaml):
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cert-manager-rules
  namespace: cert-manager
  labels:
    release: prometheus-stack
spec:
  groups:
  - name: cert-manager.rules
    rules:
    - alert: CertManagerAbsent
      expr: absent(up{job="cert-manager"})
      for: 10m
      labels:
        severity: critical
```

**PrometheusRules déployées**:
- **ArgoCD**: 14 alertes
- **Cert-Manager**: 5 alertes
- **Ingress-NGINX**: 5 alertes
- **Longhorn**: 3 alertes
- **MetalLB**: 8 alertes
- **External-DNS**: 8 alertes

### Configurer Alertmanager

**Config via values** (config-prod.yaml):
```yaml
prometheusStack:
  alertmanager:
    enabled: true
    config:
      global:
        slack_api_url: 'https://hooks.slack.com/services/XXX'
      route:
        receiver: 'slack-notifications'
        group_by: ['alertname', 'cluster', 'service']
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 12h
      receivers:
      - name: 'slack-notifications'
        slack_configs:
        - channel: '#alerts'
          title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
          text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
```

## Monitoring Best Practices

### ServiceMonitor Pattern

**Créer un ServiceMonitor** pour exposer des métriques:

```yaml
# kustomize/servicemonitor.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app-metrics
  labels:
    app: my-app
spec:
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
  selector:
    app: my-app

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  # Note: label 'release' injecté par Kustomize via commonLabels
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
  - port: metrics
    interval: 30s
```

**Utiliser Kustomize avec commonLabels** (pattern recommandé):

```yaml
# kustomize/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - servicemonitor.yaml

# ApplicationSet injecte le label dynamiquement
# dans applicationset.yaml:
kustomize:
  commonLabels:
    release: '{{ .features.monitoring.release }}'
```

Ce pattern évite les valeurs en dur et utilise la configuration centralisée (`features.monitoring.release` dans `config.yaml`).

### Metrics Cardinality

**Attention à la cardinalité**:
- Éviter labels avec valeurs uniques (user_id, request_id)
- Limiter le nombre de labels
- Utiliser label values connues (status: 200/404/500, pas toutes les valeurs)

**Vérifier la cardinalité**:
```promql
# Top 10 metrics by cardinality
topk(10, count by (__name__)({__name__=~".+"}))
```

## Troubleshooting

### Grafana login fail

**Symptôme**: Cannot login to Grafana

**Avec OIDC (Keycloak)**:
1. Vérifier que Keycloak est accessible: https://keycloak.gigix
2. Vérifier le client "grafana" dans Keycloak
3. Vérifier les logs Grafana:
   ```bash
   kubectl logs -n monitoring deployment/prometheus-stack-grafana | grep -i oidc
   ```

**Avec admin local** (fallback):
```bash
# Get password
kubectl get secret -n monitoring prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Reset password (recreate secret)
kubectl delete secret -n monitoring prometheus-stack-grafana
kubectl rollout restart -n monitoring deployment/prometheus-stack-grafana
```

### Prometheus out of disk

**Symptôme**: Prometheus crashloop, "out of disk space"

**Vérifications**:
```bash
# PVC usage
kubectl get pvc -n monitoring

# Prometheus retention
kubectl get prometheus -n monitoring -o yaml | grep retention
```

**Solutions**:
- **Augmenter storage**: Modifier config storage size
- **Réduire retention**: `retention: "3d"` au lieu de "7d"
- **Nettoyer manuellement**: Restart Prometheus (perd les données)

### Metrics not collected

**Symptôme**: ServiceMonitor créé mais pas de métriques

**Vérifications**:
```bash
# ServiceMonitor existe?
kubectl get servicemonitor -n my-namespace

# Service a le bon label?
kubectl get svc -n my-namespace --show-labels

# Prometheus targets
# Aller dans Prometheus UI → Status → Targets
# Chercher votre ServiceMonitor

# Logs Prometheus
kubectl logs -n monitoring prometheus-prometheus-stack-kube-prom-prometheus-0
```

**Causes courantes**:
- **Label mismatch**: Service labels != ServiceMonitor selector
- **Wrong namespace**: ServiceMonitor et Service dans namespaces différents
- **No `release: prometheus-stack` label**: ServiceMonitor doit avoir ce label
- **Endpoint inaccessible**: Port fermé, network policy, etc.

### Alerts not firing

**Symptôme**: PrometheusRule créé mais pas d'alertes

**Vérifications**:
```bash
# PrometheusRule existe?
kubectl get prometheusrule -n my-namespace

# Prometheus rules (UI)
# Prometheus → Status → Rules
# Chercher votre rule

# Alertmanager config
kubectl get secret -n monitoring alertmanager-prometheus-stack-kube-prom-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

**Causes courantes**:
- **Label manquant**: PrometheusRule doit avoir `release: prometheus-stack`
- **Query invalide**: Tester la query dans Prometheus UI
- **`for` duration**: Alert pas encore fired (attendre)
- **Alertmanager routing**: Alert fired mais pas routée

## Docs

- [Kube-Prometheus-Stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Alertmanager Documentation](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [PromQL Cheat Sheet](https://promlabs.com/promql-cheat-sheet/)
