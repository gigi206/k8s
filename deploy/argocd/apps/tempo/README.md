# Tempo - Distributed Tracing

Grafana Tempo pour le tracing distribué avec intégration Istio Ambient et corrélation Loki.

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │           Grafana                   │
                    │  ┌─────────┐  ┌─────────┐  ┌─────┐ │
                    │  │ Tempo   │←→│  Loki   │  │Prom │ │
                    │  │datasrc  │  │datasrc  │  │     │ │
                    │  └────┬────┘  └────┬────┘  └─────┘ │
                    └───────┼────────────┼───────────────┘
                            │            │
            ┌───────────────┴───┐   ┌────┴────┐
            │      Tempo        │   │  Loki   │
            │  (OTLP :4317)     │   │  :3100  │
            └─────────┬─────────┘   └────┬────┘
                      │                  │
      ┌───────────────┼──────────────────┼───────────────┐
      │  Istio        │                  │   Alloy       │
      │  (ztunnel +   ├──────────────────┤   (logs)      │
      │   waypoints)  │     traces       │               │
      └───────────────┴──────────────────┴───────────────┘
```

## Modes de tracing avec Istio Ambient

### Mode L4 (ztunnel uniquement) - Configuration par défaut

Le ztunnel capture les métriques TCP/L4 pour tout le trafic dans le mesh. Ce mode est actif par défaut dès qu'un namespace a le label `istio.io/dataplane-mode=ambient`.

**Métriques disponibles** :
- Connexions TCP (ouvertes, fermées, erreurs)
- Bytes envoyés/reçus
- Latence TCP

**Limitations** :
- Pas de visibilité HTTP (méthodes, codes de réponse, headers)
- Pas de propagation de trace ID automatique
- Pas de spans HTTP détaillés

### Mode L7 (ztunnel + waypoints) - Tracing complet

Les waypoints ajoutent le traitement L7 et génèrent des spans HTTP complets pour Tempo.

**Fonctionnalités supplémentaires** :
- Spans HTTP avec méthode, URL, code de réponse
- Propagation automatique des trace IDs
- Métriques HTTP (latence, taux d'erreur par endpoint)
- Retries, timeouts, circuit breaking

## Activer le tracing L7 avec Waypoints

### Étape 1 : Activer le mode ambient sur les namespaces cibles

```bash
# Exemple pour le namespace monitoring
kubectl label namespace monitoring istio.io/dataplane-mode=ambient
```

Ou via le fichier namespace.yaml :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    name: monitoring
    istio.io/dataplane-mode: ambient
```

### Étape 2 : Créer les Waypoint Gateways

Créer `deploy/argocd/apps/tempo/resources/waypoints.yaml` :

```yaml
---
# =============================================================================
# Istio Waypoint Proxies for L7 Tracing
# =============================================================================
# Waypoint proxies enable L7 features (HTTP metrics, tracing, retries) in
# Istio Ambient mode. Without waypoints, only L4 features are available.
#
# Each namespace that needs L7 tracing should:
# 1. Be labeled with istio.io/dataplane-mode=ambient
# 2. Have a Waypoint Gateway deployed
#
# The Waypoint will intercept traffic and generate spans for Tempo.
# =============================================================================

# Waypoint for monitoring namespace (Prometheus, Grafana, Alertmanager)
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: monitoring
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
   - name: mesh
      port: 15008
      protocol: HBONE

# Waypoint for keycloak namespace (Identity Provider)
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: keycloak
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
   - name: mesh
      port: 15008
      protocol: HBONE

# Waypoint for oauth2-proxy namespace (Authentication proxy)
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: oauth2-proxy
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
   - name: mesh
      port: 15008
      protocol: HBONE
```

### Étape 3 : Activer les waypoints dans la configuration

Modifier `deploy/argocd/config/config.yaml` :

```yaml
features:
  tracing:
    enabled: true
    provider: "tempo"
    waypoints:
      enabled: true  # Active le déploiement des waypoints
```

### Étape 4 : Vérifier le déploiement

```bash
# Vérifier les namespaces avec ambient mode
kubectl get namespace -l istio.io/dataplane-mode=ambient

# Vérifier les waypoints déployés
kubectl get gateway -A -l istio.io/waypoint-for=service

# Vérifier les pods waypoint
kubectl get pods -A -l gateway.networking.k8s.io/gateway-name=waypoint
```

## Corrélation Logs ↔ Traces

| Direction | Mécanisme | Configuration |
|-----------|-----------|---------------|
| **Logs → Traces** | Loki `derivedFields` extrait `traceID` via regex | Datasource Loki dans Grafana |
| **Traces → Logs** | Tempo `tracesToLogsV2` filtre Loki par trace_id | Datasource Tempo dans Grafana |
| **Traces → Metrics** | Tempo `tracesToMetrics` corrèle avec Prometheus | Datasource Tempo dans Grafana |

### Utilisation dans Grafana

1. **Logs → Traces** : Dans Explore → Loki, les logs contenant un `trace_id` affichent un lien cliquable vers Tempo
2. **Traces → Logs** : Dans Explore → Tempo, chaque span affiche un bouton "Logs for this span"
3. **Service Map** : Tempo génère automatiquement une carte des services basée sur les traces

## Configuration

### Variables disponibles (config/dev.yaml)

```yaml
tempo:
  namespace: tempo
  version: "1.10.3"
  retention: "24h"
  resources:
    requests:
      cpu: "100m"
      memory: "256Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
  persistence:
    enabled: true
    size: "5Gi"
```

### Receivers configurés

| Protocol | Port | Usage |
|----------|------|-------|
| OTLP gRPC | 4317 | Istio, applications instrumentées |
| OTLP HTTP | 4318 | Applications web, browsers |
| Zipkin | 9411 | Compatibilité legacy Istio |

## Troubleshooting

### Pas de traces visibles

1. Vérifier que Istio envoie bien les traces :
```bash
kubectl logs -n istio-system -l app=istiod | grep -i trac
```

2. Vérifier la configuration OTLP dans Istio :
```bash
kubectl get configmap istio -n istio-system -o yaml | grep -A10 extensionProviders
```

3. Vérifier que Tempo reçoit les traces :
```bash
kubectl logs -n tempo -l app.kubernetes.io/name=tempo | grep -i span
```

### Traces incomplètes (pas de spans HTTP)

Les spans HTTP nécessitent des waypoints. Vérifier :

1. Le namespace a le label ambient :
```bash
kubectl get namespace <ns> --show-labels | grep dataplane-mode
```

2. Un waypoint est déployé dans le namespace :
```bash
kubectl get gateway -n <ns> -l istio.io/waypoint-for=service
```

3. Le pod waypoint est Running :
```bash
kubectl get pods -n <ns> -l gateway.networking.k8s.io/gateway-name=waypoint
```

## Monitoring

### Prometheus Alerts

9 alertes sont configurées pour Tempo :

**Disponibilité**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| TempoDown | critical | Tempo indisponible (5m) |
| TempoPodDown | critical | Pod Tempo indisponible (5m) |
| TempoPodCrashLooping | critical | Pod en restart loop (10m) |
| TempoPodNotReady | warning | Pod non ready (10m) |

**Performance**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| TempoHighIngestionRate | warning | > 10000 spans/s (10m) |
| TempoIngestionFailures | warning | Spans reçus mais pas de traces créées (10m) |
| TempoHighQueryLatency | warning | Latence p99 queries > 10s (10m) |

**Stockage**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| TempoDiskUsageHigh | warning | PVC > 80% (10m) |
| TempoDiskAlmostFull | critical | PVC > 90% (5m) |

### Métriques clés

```promql
# Ingestion
rate(tempo_distributor_spans_received_total[5m])
tempo_ingester_traces_created_total

# Queries
histogram_quantile(0.99, rate(tempo_query_frontend_request_duration_seconds_bucket[5m]))
```

## Références

- [Grafana Tempo Documentation](https://grafana.com/docs/tempo/latest/)
- [Istio Ambient Mode](https://istio.io/latest/docs/ambient/)
- [Istio Waypoints](https://istio.io/latest/docs/ambient/usage/waypoint/)
- [OpenTelemetry Protocol (OTLP)](https://opentelemetry.io/docs/specs/otlp/)
