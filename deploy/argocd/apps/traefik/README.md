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
traefik (Wave 40)
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

En dev, le dashboard Traefik est accessible via port-forward :

```bash
kubectl port-forward -n traefik svc/traefik 9000:9000
# Ouvrir http://localhost:9000/dashboard/
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

# Port-forward direct
kubectl port-forward -n traefik svc/traefik 9000:9000

# Ouvrir http://localhost:9000/dashboard/
```

## Documentation

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Traefik Helm Chart](https://github.com/traefik/traefik-helm-chart)
- [Gateway API avec Traefik](https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/)
- [Dashboard Grafana](https://grafana.com/grafana/dashboards/17347-traefik-official-kubernetes-dashboard/)

## Notes

- Necessite `gateway-api-controller` (Wave 15) deja deploye pour les CRDs Gateway API
- Coexiste avec nginx-ingress et istio - pas de conflit
- MetalLB assigne automatiquement une IP au service LoadBalancer
- IngressClass `traefik` n'est PAS definie comme default (evite les conflits)
