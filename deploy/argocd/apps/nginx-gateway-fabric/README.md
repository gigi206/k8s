# NGINX Gateway Fabric

NGINX Gateway Fabric est l'implémentation officielle de NGINX pour Kubernetes Gateway API (nouvelle génération de gestion du trafic).

## Différences avec nginx-ingress

| Feature | nginx-ingress (classique) | nginx-gateway-fabric (Gateway API) |
|---------|--------------------------|-----------------------------------|
| API | `Ingress` resources | `Gateway`, `HTTPRoute`, `GRPCRoute`, `TLSRoute` |
| Multi-tenant | Limité | Natif (role-based) |
| TCP/UDP | Via annotations | Support natif |
| Expressivité | Limitée | Très riche (weighted routing, header matching, etc.) |
| Maturity | Stable (GA) | Stable (GA depuis K8s 1.31) |

## État actuel

**Application DÉSACTIVÉE par défaut** - coexiste avec nginx-ingress pour transition progressive.

Pour activer (déploiement manuel) :
```bash
kubectl apply -f deploy/argocd/apps/nginx-gateway-fabric/applicationset.yaml
```

## Architecture de déploiement

```
nginx-ingress (Wave 40)          → Pour apps utilisant ressources Ingress
  ↓
nginx-gateway-fabric (Wave 41)   → Pour nouvelles apps utilisant Gateway API
  ↓
  Crée GatewayClass: nginx-gwf
```

Les deux peuvent coexister :
- **Ingress classiques** → nginx-ingress (IngressClass: `nginx`)
- **HTTPRoute / Gateway** → nginx-gateway-fabric (GatewayClass: `nginx-gwf`)

## Configuration

### Dev (config/dev.yaml)

```yaml
nginxGatewayFabric:
  enabled: false               # À activer manuellement
  replicas: 1
  serviceType: LoadBalancer    # Utilise MetalLB
  gatewayClassName: nginx-gwf  # GatewayClass créée
```

### Prod (config/prod.yaml)

```yaml
nginxGatewayFabric:
  enabled: false
  replicas: 2                  # HA
  serviceType: LoadBalancer
  gatewayClassName: nginx-gwf
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

## Utilisation

### 1. Créer un Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: nginx-gwf
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
      - name: my-cert-secret
```

### 3. Créer une HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: default
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
    - name: my-service
      port: 8080
```

## Exemples avancés

### Weighted routing (Canary)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: canary-route
spec:
  parentRefs:
  - name: my-gateway
  hostnames:
  - "app.example.com"
  rules:
  - backendRefs:
    - name: app-v1
      port: 8080
      weight: 90
    - name: app-v2
      port: 8080
      weight: 10
```

### Header-based routing

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: header-route
spec:
  parentRefs:
  - name: my-gateway
  rules:
  - matches:
    - headers:
      - name: "X-Version"
        value: "beta"
    backendRefs:
    - name: app-beta
      port: 8080
  - backendRefs:
    - name: app-stable
      port: 8080
```

## Vérification

```bash
# Vérifier l'application ArgoCD
kubectl get application -n argo-cd nginx-gateway-fabric

# Vérifier le déploiement
kubectl get pods -n nginx-gateway

# Vérifier la GatewayClass
kubectl get gatewayclass nginx-gwf

# Vérifier les Gateways
kubectl get gateway -A

# Vérifier les HTTPRoutes
kubectl get httproute -A
```

## Migration depuis nginx-ingress

Pour migrer une application de Ingress → HTTPRoute :

**Avant (Ingress)** :
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 8080
```

**Après (Gateway + HTTPRoute)** :
```yaml
# Gateway (réutilisable pour plusieurs HTTPRoute)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
spec:
  gatewayClassName: nginx-gwf
  listeners:
  - name: http
    protocol: HTTP
    port: 80
---
# HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
spec:
  parentRefs:
  - name: shared-gateway
  hostnames:
  - "myapp.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: myapp
      port: 8080
```

## Avantages de Gateway API

✅ **Role-based access control** : Séparation cluster ops / app devs
✅ **Portabilité** : Même API pour tous les controllers (Nginx, Istio, HAProxy, etc.)
✅ **Expressivité** : Routing avancé (headers, weights, mirrors, redirects)
✅ **Typed resources** : Validation forte au niveau API
✅ **Multi-protocol** : HTTP, HTTPS, TCP, UDP, gRPC natifs
✅ **Extension points** : Support des features custom via CRDs

## Documentation

- [NGINX Gateway Fabric Docs](https://docs.nginx.com/nginx-gateway-fabric/)
- [Gateway API Docs](https://gateway-api.sigs.k8s.io/)
- [NGINX Gateway Fabric GitHub](https://github.com/nginxinc/nginx-gateway-fabric)

## Notes

- Nécessite `gateway-api-controller` (Wave 15) déjà déployé pour les CRDs
- Coexiste avec nginx-ingress - pas de conflit
- MetalLB assigne automatiquement une IP au service LoadBalancer
- Utilise la GatewayClass `nginx-gwf` (différent de nginx-ingress)
