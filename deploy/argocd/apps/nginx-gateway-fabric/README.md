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
nginx-ingress          → Pour apps utilisant ressources Ingress
  ↓
nginx-gateway-fabric   → Pour nouvelles apps utilisant Gateway API
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

## OAuth2 Authentication (SnippetsFilter)

nginx-gateway-fabric ne supporte pas nativement `ext_authz` (prévu pour v2.7.0). Un workaround utilisant `SnippetsFilter` avec la directive `auth_request` de NGINX est implémenté.

### Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Client    │────▶│ NGINX Gateway    │────▶│ OAuth2 Proxy    │
└─────────────┘     │ (auth_request)   │     │ (auth check)    │
                    └──────────────────┘     └─────────────────┘
                           │                      │
                           │ ◀── 200 OK ──────────┘
                           ▼
                    ┌──────────────┐
                    │  Backend App │
                    │ (prometheus) │
                    └──────────────┘
```

### Configuration

1. **SnippetsFilter** (oauth2-proxy namespace) : Définit la directive `auth_request`
2. **ReferenceGrant** (nginx-gateway namespace) : Autorise les HTTPRoutes à référencer le SnippetsFilter
3. **HTTPRoute filter** : Ajoute le SnippetsFilter via `ExtensionRef`

### SnippetsFilter

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: SnippetsFilter
metadata:
  name: oauth2-auth
  namespace: nginx-gateway
spec:
  snippets:
   - context: http.server.location
      value: |
        auth_request /oauth2/auth;
        auth_request_set $user $upstream_http_x_auth_request_user;
        auth_request_set $email $upstream_http_x_auth_request_email;
        error_page 401 = /oauth2/start?rd=$scheme://$host$request_uri;
```

### ReferenceGrant

Permet aux HTTPRoutes d'autres namespaces de référencer le SnippetsFilter :

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-nginx-gateway-snippets
  namespace: nginx-gateway
spec:
  from:
   - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: monitoring  # Namespace de l'application
  to:
   - group: gateway.nginx.org
      kind: SnippetsFilter
```

### HTTPRoute avec OAuth2

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-protected-app
  namespace: monitoring
spec:
  parentRefs:
   - name: default-gateway
      namespace: nginx-gateway
  hostnames:
   - "my-app.k8s.lan"
  rules:
   - matches:
       - path:
            type: PathPrefix
            value: /
      filters:
       - type: ExtensionRef
          extensionRef:
            group: gateway.nginx.org
            kind: SnippetsFilter
            name: oauth2-auth
      backendRefs:
       - name: my-app-service
          port: 8080
```

### Applications protégées

| Application | Namespace | Hostname |
|-------------|-----------|----------|
| Prometheus | monitoring | prometheus.k8s.lan |
| Alertmanager | monitoring | alertmanager.k8s.lan |
| Hubble UI | kube-system | hubble.k8s.lan |

### Vérification

```bash
# SnippetsFilter créé
kubectl get snippetsfilter -n nginx-gateway

# ReferenceGrants créés
kubectl get referencegrant -A | grep nginx-gateway

# Test accès (doit rediriger vers Keycloak)
curl -k -I https://prometheus.k8s.lan
```

> **Voir aussi** : `apps/oauth2-proxy/README.md` pour la documentation complète.

## HTTPS Backends (BackendTLSPolicy)

Certaines applications (Ceph Dashboard, NeuVector) exposent leur interface en HTTPS. nginx-gateway-fabric utilise `BackendTLSPolicy` pour se connecter aux backends HTTPS.

### Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Client    │────▶│ NGINX Gateway    │────▶│ Backend HTTPS   │
└─────────────┘     │ (BackendTLSPolicy│     │ (Ceph Dashboard)│
                    │  + CA validation)│     │ port 8443       │
                    └──────────────────┘     └─────────────────┘
```

### Configuration

1. **BackendTLSPolicy** : Configure la validation TLS vers le backend
2. **ExternalSecret** : Synchronise le CA du cluster pour la validation
3. **Certificate** : (optionnel) Émet un certificat pour le backend

### BackendTLSPolicy

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: ceph-dashboard-tls
  namespace: rook-ceph
spec:
  targetRefs:
   - group: ""
      kind: Service
      name: ceph-dashboard-https
  validation:
    caCertificateRefs:
     - group: ""
        kind: Secret
        name: ceph-dashboard-backend-ca
    hostname: rook-ceph-mgr-dashboard.rook-ceph.svc.cluster.local
```

### ExternalSecret pour CA

nginx-gateway-fabric requiert un Secret de type `kubernetes.io/tls` avec la clé `ca.crt` :

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ceph-dashboard-backend-ca
  namespace: rook-ceph
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: cert-manager-ca-secrets
  target:
    name: ceph-dashboard-backend-ca
    template:
      type: kubernetes.io/tls
  data:
   - secretKey: ca.crt
      remoteRef:
        key: root-ca-secret
        property: tls.crt
   - secretKey: tls.crt
      remoteRef:
        key: root-ca-secret
        property: tls.crt
   - secretKey: tls.key
      remoteRef:
        key: root-ca-secret
        property: tls.key
```

### Applications HTTPS Backend

| Application | Namespace | Port | Documentation |
|-------------|-----------|------|---------------|
| Ceph Dashboard | rook-ceph | 8443 | `apps/rook/README.md` |

### Vérification

```bash
# BackendTLSPolicy créé
kubectl get backendtlspolicy -n rook-ceph

# Secret CA syncé
kubectl get secret -n rook-ceph ceph-dashboard-backend-ca

# Test accès
curl -k https://ceph.k8s.lan
```

> **Voir aussi** : `apps/rook/README.md` section "HTTPS Backend avec nginx-gateway-fabric".

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

## Troubleshooting

### Controller ne démarre pas

```bash
# Vérifier les pods
kubectl get pods -n nginx-gateway

# Logs du controller
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric

# Events
kubectl get events -n nginx-gateway --sort-by='.lastTimestamp'
```

### GatewayClass non prête

```bash
# Status de la GatewayClass
kubectl describe gatewayclass nginx-gwf

# Vérifier le controller
kubectl get deployment -n nginx-gateway
```

### Gateway ne devient pas Ready

```bash
# Status détaillé
kubectl describe gateway <name>

# Vérifier les listeners
kubectl get gateway <name> -o jsonpath='{.status.listeners[*].conditions}'

# Logs pour cette gateway
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric | grep <gateway-name>
```

### HTTPRoute ne fonctionne pas

```bash
# Status de l'HTTPRoute
kubectl describe httproute <name>

# Vérifier le parentRef
kubectl get httproute <name> -o jsonpath='{.status.parents}'

# Vérifier le service backend
kubectl get svc <backend-service> -n <namespace>

# Vérifier les endpoints
kubectl get endpoints <backend-service> -n <namespace>
```

### Service backend inaccessible (502/503)

```bash
# Vérifier que les pods backend sont prêts
kubectl get pods -n <namespace> -l app=<backend-app>

# Tester la connectivité directe
kubectl exec -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric -- \
  curl -s http://<backend-service>.<namespace>.svc:port

# Logs NGINX
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric | grep error
```

### TLS ne fonctionne pas

```bash
# Vérifier le secret TLS
kubectl get secret <tls-secret> -n <namespace>

# Vérifier que le certificat est valide
kubectl get secret <tls-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# Vérifier le listener HTTPS
kubectl get gateway <name> -o jsonpath='{.status.listeners[?(@.name=="https")].conditions}'
```

## Documentation

- [NGINX Gateway Fabric Docs](https://docs.nginx.com/nginx-gateway-fabric/)
- [Gateway API Docs](https://gateway-api.sigs.k8s.io/)
- [NGINX Gateway Fabric GitHub](https://github.com/nginxinc/nginx-gateway-fabric)

## Notes

- Nécessite `gateway-api-controller` déjà déployé pour les CRDs
- Coexiste avec nginx-ingress - pas de conflit
- MetalLB assigne automatiquement une IP au service LoadBalancer
- Utilise la GatewayClass `nginx-gwf` (différent de nginx-ingress)
