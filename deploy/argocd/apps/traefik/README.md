# Traefik

Traefik est un reverse proxy et load balancer moderne concu pour les environnements cloud-native et Kubernetes.

## Differences avec nginx-ingress

| Feature | nginx-ingress (classique) | Traefik |
|---------|--------------------------|---------|
| Configuration | Annotations Ingress | CRDs natifs (IngressRoute, Middleware) |
| Gateway API | Support limite | Support natif complet |
| Dashboard | Non inclus | Dashboard web integre |
| Auto-discovery | Via ConfigMap | Automatique via labels/annotations |
| Middlewares | Via annotations | CRDs dedies (retry, rate-limit, etc.) |
| Let's Encrypt | Via cert-manager | Support ACME natif |

## Etat actuel

**Application DESACTIVEE par defaut** - non incluse dans le deploiement automatique.

Pour activer (deploiement manuel) :
```bash
kubectl apply -f deploy/argocd/apps/traefik/applicationset.yaml
```

## Architecture de deploiement

```
traefik
  |
  +-- Cree IngressClass: traefik
  +-- Cree GatewayClass: traefik
  |
  +-- Entrypoints:
      +-- web (port 80)
      +-- websecure (port 443)
```

Traefik peut coexister avec d'autres ingress controllers :
- **Ingress classiques** -> nginx-ingress (IngressClass: `nginx`) ou istio (IngressClass: `istio`)
- **IngressRoute Traefik** -> traefik (IngressClass: `traefik`)
- **Gateway API** -> traefik (GatewayClass: `traefik`)

## Configuration

### Dev (config/dev.yaml)

```yaml
traefik:
  deployment:
    kind: Deployment
    replicas: 1
  service:
    type: LoadBalancer
  ingressClass:
    enabled: true
    isDefaultClass: false
  gatewayClass:
    enabled: true
    name: traefik
  dashboard:
    enabled: true  # Active en dev
  logs:
    level: INFO
    accessLogs: true
```

### Prod (config/prod.yaml)

```yaml
traefik:
  deployment:
    kind: Deployment
    replicas: 3  # HA
  service:
    type: LoadBalancer
  ingressClass:
    enabled: true
    isDefaultClass: false
  gatewayClass:
    enabled: true
    name: traefik
  dashboard:
    enabled: false  # Desactive en prod
  logs:
    level: ERROR
    accessLogs: false
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 512Mi
```

## Utilisation

### 1. Avec ressources Ingress standard

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
 - host: myapp.example.com
    http:
      paths:
     - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 8080
```

### 2. Avec IngressRoute (CRD Traefik)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
spec:
  entryPoints:
   - websecure
  routes:
 - match: Host(`myapp.example.com`)
    kind: Rule
    services:
   - name: my-app
      port: 8080
    middlewares:
   - name: my-ratelimit
  tls:
    certResolver: letsencrypt
```

### 3. Avec Gateway API

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
spec:
  gatewayClassName: traefik
  listeners:
 - name: http
    protocol: HTTP
    port: 80
 - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
     - name: my-cert
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-route
spec:
  parentRefs:
 - name: my-gateway
  hostnames:
 - "myapp.example.com"
  rules:
 - matches:
   - path:
        type: PathPrefix
        value: /
    backendRefs:
   - name: my-app
      port: 8080
```

## Middlewares Traefik

Traefik offre des middlewares puissants via CRDs :

### Rate Limiting

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
spec:
  rateLimit:
    average: 100
    burst: 50
```

### Basic Auth

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth
spec:
  basicAuth:
    secret: auth-secret
```

### Redirect HTTPS

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

### Headers

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
spec:
  headers:
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    stsPreload: true
    forceSTSHeader: true
```

## Dashboard

### Accès via HTTPRoute (recommandé)

Quand `traefik.dashboard.expose: true` et `features.gatewayAPI.enabled: true`, le dashboard est exposé via HTTPRoute :

- **URL** : https://traefik.k8s.lan/dashboard/
- **Redirection automatique** : `/` -> `/dashboard/`
- **Protection OAuth2** : Authentification via Keycloak (si `features.oauth2Proxy.enabled: true`)

### Structure des fichiers

```
kustomize/httproute/
 - httproute.yaml       # HTTPRoute avec 3 règles (redirect, oauth2, backend)
 - service.yaml         # Service exposant l'API dashboard (port 8080)
 - referencegrant.yaml  # Autorise référence cross-namespace vers oauth2-proxy

kustomize/oauth2-authz/
 - middleware.yaml      # Middleware chain vers oauth2-proxy forward-auth
```

### ReferenceGrant

Le `ReferenceGrant` permet à l'HTTPRoute (namespace `traefik`) de référencer le service `oauth2-proxy` (namespace `oauth2-proxy`) pour le callback OAuth2 :

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-traefik-to-oauth2-proxy
  namespace: oauth2-proxy
spec:
  from:
   - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: traefik
  to:
   - group: ""
      kind: Service
      name: oauth2-proxy
```

### Accès via port-forward (alternatif)

```bash
kubectl port-forward -n traefik svc/traefik 8080:8080
# Ouvrir http://localhost:8080/dashboard/
```

## Verification

```bash
# Verifier l'application ArgoCD
kubectl get application -n argo-cd traefik

# Verifier le deploiement
kubectl get pods -n traefik

# Verifier l'IngressClass
kubectl get ingressclass traefik

# Verifier la GatewayClass
kubectl get gatewayclass traefik

# Verifier les entrypoints
kubectl get svc -n traefik
```

## Monitoring

L'application inclut :
- **PrometheusRules** : Alertes pour disponibilite, latence, erreurs 4xx/5xx
- **Dashboard Grafana** : Dashboard officiel Kubernetes (ID 17347)

### Alertes configurees

| Alerte | Severite | Description |
|--------|----------|-------------|
| TraefikDown | critical | Traefik ne reporte plus de metriques |
| TraefikPodDown | critical | Aucun pod Traefik disponible |
| TraefikConfigReloadFailure | critical | Echec du rechargement de config |
| TraefikHighLatency | high | Latence moyenne > 2s |
| TraefikTooMany5xx | high | Taux d'erreurs 5xx > 5% |
| TraefikTooMany4xx | warning | Taux d'erreurs 4xx > 10% |
| TraefikHighConnectionCount | warning | > 5000 connexions ouvertes |
| TraefikServiceDown | warning | Service backend indisponible |
| TraefikPodCrashLooping | warning | Pod en crash loop |

## Troubleshooting

### Traefik ne démarre pas

```bash
# Vérifier les pods
kubectl get pods -n traefik

# Logs détaillés
kubectl logs -n traefik -l app.kubernetes.io/name=traefik

# Events
kubectl get events -n traefik --sort-by='.lastTimestamp'
```

### IngressRoute ne fonctionne pas

```bash
# Vérifier que l'IngressRoute existe
kubectl get ingressroute -A

# Status de l'IngressRoute
kubectl describe ingressroute <name> -n <namespace>

# Vérifier les middlewares référencés
kubectl get middleware -n <namespace>

# Logs Traefik pour cette route
kubectl logs -n traefik -l app.kubernetes.io/name=traefik | grep <hostname>
```

### Gateway API route pas active

```bash
# Vérifier la GatewayClass
kubectl get gatewayclass traefik

# Vérifier la Gateway
kubectl describe gateway <name>

# Vérifier l'HTTPRoute
kubectl describe httproute <name>

# Status des listeners
kubectl get gateway <name> -o jsonpath='{.status.listeners}'
```

### Erreurs TLS / Certificats

```bash
# Vérifier le secret TLS
kubectl get secret <tls-secret> -n <namespace>

# Vérifier que cert-manager a créé le certificat
kubectl get certificate -A

# Logs cert-manager si ACME
kubectl logs -n cert-manager -l app=cert-manager
```

### Service backend inaccessible (503)

```bash
# Vérifier le service backend
kubectl get svc <backend-service> -n <namespace>

# Vérifier les endpoints
kubectl get endpoints <backend-service> -n <namespace>

# Vérifier les pods backend
kubectl get pods -n <namespace> -l app=<backend-app>

# Test direct depuis Traefik
kubectl exec -n traefik -l app.kubernetes.io/name=traefik -- wget -q -O- http://<backend-service>.<namespace>.svc:port
```

### Dashboard inaccessible

```bash
# Vérifier que le dashboard est activé
kubectl get deployment -n traefik traefik -o yaml | grep dashboard

# Vérifier l'HTTPRoute
kubectl get httproute -n traefik traefik-dashboard
kubectl describe httproute -n traefik traefik-dashboard

# Vérifier le service API
kubectl get svc -n traefik traefik-api

# Vérifier le ReferenceGrant (pour OAuth2 callback)
kubectl get referencegrant -n oauth2-proxy

# Port-forward direct (bypass HTTPRoute)
kubectl port-forward -n traefik svc/traefik 8080:8080
# Ouvrir http://localhost:8080/dashboard/
```

## Documentation

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Traefik Helm Chart](https://github.com/traefik/traefik-helm-chart)
- [Gateway API avec Traefik](https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/)
- [Dashboard Grafana](https://grafana.com/grafana/dashboards/17347-traefik-official-kubernetes-dashboard/)

## Gateway API CRDs

**Traefik installe et gère les CRDs Gateway API** (standard channel) directement via son chart Helm. Cette fonctionnalité ne peut pas être désactivée.

### Comportement

Quand `features.gatewayAPI.enabled: true` :
- Traefik installe automatiquement les CRDs Gateway API (standard channel)
- Le chart Helm crée la GatewayClass `traefik`
- Le Gateway `default-gateway` est créé via **kustomize** (pas Helm) en raison d'un bug de type dans le chart Helm (comparaison int vs string pour les ports)
- `gateway-api-controller` n'est PAS déployé (évite les conflits de CRDs)

### Pourquoi le Gateway via kustomize ?

Le chart Helm Traefik (v38+) a un bug qui compare les ports des listeners Gateway (int) avec les ports des entrypoints passés via `parameters` (string), causant une erreur `incompatible types for comparison`. La solution est de désactiver le Gateway Helm (`gateway.enabled: false`) et de le créer via `kustomize/certificate/gateway.yaml`.

### Vérification des CRDs

```bash
# Vérifier les CRDs installés par Traefik
kubectl get crd | grep gateway.networking

# Vérifier les annotations de version
kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations}'
# Devrait montrer bundle-version et channel: standard

# Vérifier le Gateway créé via kustomize
kubectl get gateway -n traefik
```

### Coexistence avec d'autres controllers

Si vous avez besoin d'utiliser un autre Gateway API controller (Istio, APISIX, etc.), ne déployez pas Traefik car il installerait ses propres CRDs qui pourraient entrer en conflit.

## Notes

- **Pas besoin de `gateway-api-controller`** - Traefik installe ses propres CRDs Gateway API
- Coexiste avec nginx-ingress et istio (pour Ingress classique) - pas de conflit
- MetalLB assigne automatiquement une IP au service LoadBalancer
- IngressClass `traefik` n'est PAS definie comme default (evite les conflits)
