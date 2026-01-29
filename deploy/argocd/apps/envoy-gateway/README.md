# Envoy Gateway

Implémentation officielle d'EnvoyProxy pour Gateway API.

## Overview

**Envoy Gateway** est l'implémentation de référence du projet Envoy pour l'API Gateway de Kubernetes. Il fournit un contrôleur Gateway API et déploie automatiquement des proxies Envoy pour gérer le trafic ingress.

- **Documentation**: https://gateway.envoyproxy.io/
- **Repository**: https://github.com/envoyproxy/gateway
- **Helm Chart**: `oci://docker.io/envoyproxy/gateway-helm`
- **Version Envoy Gateway**: v1.6.2
- **Compatibilité Gateway API**: v1.4.0

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Gateway API Resources                     │
│  (GatewayClass, Gateway, HTTPRoute, TLSRoute, etc.)         │
└────────────────────────┬────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────┐
│              Envoy Gateway Controller                        │
│ - Watches Gateway API resources                            │
│ - Provisions Envoy Proxy instances                         │
│ - Configures Envoy via xDS API                             │
│  Namespace: envoy-gateway-system                            │
└────────────────────────┬────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────┐
│                   Envoy Proxy Fleet                          │
│ - One deployment per Gateway resource                       │
│ - LoadBalancer service (MetalLB)                           │
│ - Handles HTTP/HTTPS/TCP traffic                           │
│  Namespace: envoy-gateway-system (configurable)             │
└─────────────────────────────────────────────────────────────┘
```

## Key Features

- **Gateway API Native**: Implémentation de référence de l'API Gateway v1.4.0
- **GatewayClass**: `envoy` (distinct de istio/nginx)
- **Automatic Proxy Provisioning**: Déploie automatiquement des Envoy proxies
- **Multi-Protocol**: HTTP, HTTPS, TCP, UDP, gRPC
- **Metrics**: Prometheus metrics sur le port 19001
- **LoadBalancer**: Intégration MetalLB pour assignation d'IP

## Activation

### Via la configuration globale (recommandé)

Envoy Gateway est activé automatiquement lorsqu'il est configuré comme provider Gateway API dans `config/config.yaml`:

```yaml
features:
  gatewayAPI:
    enabled: true
    controller:
      provider: "envoy-gateway"
      gatewayNamespace: "envoy-gateway-system"
      loadBalancerIP: "192.168.121.210"
```

Puis redéployer les ApplicationSets:

```bash
cd deploy/argocd && ./deploy-applicationsets.sh
```

### Ressources déployées automatiquement

Quand activé, les ressources suivantes sont créées:

1. **Envoy Gateway Controller** (Helm chart)
  - Deployment: `envoy-gateway` dans `envoy-gateway-system`
  - Service: metrics sur port 19001
  - GatewayClass: `envoy`

2. **Default Gateway** (`kustomize/gateway/`)
  - Gateway: `default-gateway` avec listeners HTTP (80) et HTTPS (443)
  - Certificate: `wildcard-k8s-local-tls` pour `*.{{ common.domain }}`
  - LoadBalancer IP: configurée via `features.loadBalancer.staticIPs.gateway`

3. **Cilium Network Policies** (si activé)
  - Host ingress policy: ports 80/443 vers nodes
  - Pod ingress policy: trafic vers pods envoy-gateway

4. **PrometheusRules** (si monitoring activé)
  - Alertes pour le contrôleur et les proxies

### Vérification du déploiement

```bash
# Vérifier les pods
kubectl get pods -n envoy-gateway-system

# Vérifier la GatewayClass
kubectl get gatewayclass envoy

# Vérifier la Gateway
kubectl get gateway -n envoy-gateway-system default-gateway

# Vérifier le certificat TLS
kubectl get certificate,secret -n envoy-gateway-system | grep wildcard

# Vérifier le service LoadBalancer
kubectl get svc -n envoy-gateway-system

# Vérifier les logs
kubectl logs -n envoy-gateway-system deployment/envoy-gateway -f
```

## Configuration

### Dev Environment

- **Replicas**: 1
- **CPU Request**: 100m
- **Memory Request**: 256Mi
- **Memory Limit**: 1Gi
- **Auto-sync**: Enabled

### Prod Environment

- **Replicas**: 3 (HA)
- **CPU Request**: 200m
- **Memory Request**: 512Mi
- **Memory Limit**: 2Gi
- **Auto-sync**: Disabled (manual sync)

### Configuration files

- `config/dev.yaml`: Dev environment configuration
- `config/prod.yaml`: Prod environment configuration

### Paramètres disponibles

```yaml
# config/dev.yaml
envoyGateway:
  version: "1.6.2"          # Helm chart version
  replicas: 1               # Number of controller replicas
  gatewayClassName: envoy   # GatewayClass name
  resources:
    requests:
      cpu: "100m"
      memory: "256Mi"
    limits:
      cpu: "1000m"
      memory: "1Gi"
```

## Utilisation des HTTPRoutes

Une fois Envoy Gateway déployé, vous pouvez créer des HTTPRoutes pour router le trafic vers vos services:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: my-app
spec:
  parentRefs:
 - name: default-gateway
    namespace: envoy-gateway-system
  hostnames:
 - "myapp.k8s.lan"
  rules:
 - backendRefs:
   - name: my-app-service
      port: 80
```

### Test du routage

```bash
# Récupérer l'IP du LoadBalancer
GATEWAY_IP=$(kubectl get gateway -n envoy-gateway-system default-gateway -o jsonpath='{.status.addresses[0].value}')

echo "Gateway IP: $GATEWAY_IP"

# Tester HTTP
curl -H "Host: myapp.k8s.lan" http://$GATEWAY_IP

# Tester HTTPS (avec certificat auto-signé)
curl -k -H "Host: myapp.k8s.lan" https://$GATEWAY_IP
```

## Backend CRD - HTTPS Backends avec TLS Version Control

Certains backends (comme Ceph Dashboard) n'acceptent que des versions TLS spécifiques (ex: TLS 1.3 uniquement). Le CRD `Backend` d'Envoy Gateway permet de configurer précisément la version TLS utilisée pour la connexion backend.

### Activation du Backend API

Le Backend API doit être activé dans la configuration Envoy Gateway. Ceci est fait automatiquement via le Helm values:

```yaml
config:
  envoyGateway:
    extensionApis:
      enableBackend: true
```

### Exemple: Backend TLS 1.3 pour Ceph Dashboard

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: ceph-dashboard-backend
  namespace: rook-ceph
spec:
  endpoints:
   - fqdn:
        hostname: rook-ceph-mgr-dashboard.rook-ceph.svc.cluster.local
        port: 8443
  tls:
    insecureSkipVerify: true  # Ceph utilise un certificat auto-signé
    minVersion: "1.3"         # Force TLS 1.3 minimum
    maxVersion: "1.3"         # Force TLS 1.3 maximum
    sni: rook-ceph-mgr-dashboard.rook-ceph.svc.cluster.local
```

### HTTPRoute référençant un Backend

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ceph-dashboard
  namespace: rook-ceph
spec:
  parentRefs:
   - name: default-gateway
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
   - "ceph.k8s.lan"
  rules:
   - backendRefs:
       - group: gateway.envoyproxy.io  # Important: groupe du Backend CRD
          kind: Backend                   # Important: kind Backend (pas Service)
          name: ceph-dashboard-backend
          port: 8443
```

### Vérification

```bash
# Vérifier que le Backend est créé
kubectl get backend -n rook-ceph

# Vérifier les logs Envoy pour TLS
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=default-gateway | grep -i tls

# Tester la connexion
curl -sk https://ceph.k8s.lan/
```

## OAuth2 Proxy avec SecurityPolicy (ext_authz)

Envoy Gateway supporte l'authentification externe via `SecurityPolicy` avec `extAuth`. Cette fonctionnalité permet d'intégrer OAuth2 Proxy pour protéger les HTTPRoutes.

### Limitation importante

⚠️ **Limitation**: OAuth2 Proxy's `/oauth2/auth` retourne `401` quand non authentifié. Envoy Gateway transforme cela en `403 Forbidden`. **L'utilisateur ne sera PAS automatiquement redirigé vers la page de login.**

Pour se connecter, l'utilisateur doit manuellement naviguer vers:
```
https://<host>/oauth2/start?rd=https://<host>/
```

### Configuration SecurityPolicy

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: oauth2-proxy-myapp
  namespace: my-namespace
spec:
  targetRefs:
   - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-app
  extAuth:
    failOpen: false
    http:
      backendRefs:
       - name: oauth2-proxy
          namespace: oauth2-proxy
          port: 4180
      path: /oauth2/auth
      headersToBackend:
       - X-Auth-Request-User
       - X-Auth-Request-Email
       - X-Auth-Request-Access-Token
       - X-Auth-Request-Groups
```

### ReferenceGrant requis

Pour permettre à la SecurityPolicy de référencer le service oauth2-proxy cross-namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-myns-securitypolicy
  namespace: oauth2-proxy
spec:
  from:
   - group: gateway.envoyproxy.io
      kind: SecurityPolicy
      namespace: my-namespace
  to:
   - group: ""
      kind: Service
      name: oauth2-proxy
```

### HTTPRoute compatible OAuth2

L'HTTPRoute doit inclure les routes `/oauth2/*` vers oauth2-proxy:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  parentRefs:
   - name: default-gateway
      namespace: envoy-gateway-system
  hostnames:
   - "myapp.k8s.lan"
  rules:
    # Route OAuth2 callbacks vers oauth2-proxy
   - matches:
       - path:
            type: PathPrefix
            value: /oauth2/
      backendRefs:
       - name: oauth2-proxy
          namespace: oauth2-proxy
          port: 4180
    # Route principale vers le backend
   - matches:
       - path:
            type: PathPrefix
            value: /
      backendRefs:
       - name: my-app-service
          port: 80
```

### Test de l'authentification

```bash
# Sans authentification - devrait retourner 403
curl -sk https://myapp.k8s.lan/

# Naviguer manuellement vers le login
# https://myapp.k8s.lan/oauth2/start?rd=https://myapp.k8s.lan/

# Après authentification (avec cookie), devrait fonctionner
curl -sk -b "cookie_file" https://myapp.k8s.lan/
```

### Alternative: OIDC natif d'Envoy Gateway

Pour une meilleure UX avec redirection automatique, utilisez l'OIDC natif d'Envoy Gateway au lieu d'OAuth2 Proxy:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: oidc-myapp
spec:
  targetRefs:
   - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-app
  oidc:
    provider:
      issuer: "https://keycloak.k8s.lan/realms/k8s"
    clientID: "my-app"
    clientSecret:
      name: "my-app-oidc-secret"
    redirectURL: "https://myapp.k8s.lan/oauth2/callback"
    logoutPath: "/logout"
```

L'OIDC natif gère automatiquement la redirection vers Keycloak et le callback.

## Monitoring

### Prometheus Alerts

Les alertes suivantes sont configurées :

- **EnvoyGatewayDown** (critical): Gateway controller indisponible
- **EnvoyGatewayCrashLooping** (critical): Pods en crash loop
- **EnvoyGatewayHighMemory** (high): Utilisation mémoire > 90%
- **EnvoyGatewayHighCPU** (warning): Utilisation CPU > 80%
- **EnvoyGatewayPodNotReady** (warning): Pod non ready pendant 10min

### Metrics Endpoints

- **Gateway Controller**: `http://envoy-gateway.envoy-gateway-system:19001/metrics`
- **Envoy Proxies**: `http://<proxy-service>:19001/stats/prometheus`

### Vérification des alertes

```bash
# Vérifier que les PrometheusRules sont chargées
kubectl get prometheusrules -n envoy-gateway-system

# Accéder à Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090

# Ouvrir http://localhost:9090/rules et chercher "envoy-gateway"
```

## Coexistence avec autres Gateways

Envoy Gateway peut coexister avec d'autres implémentations Gateway API :

| Gateway | GatewayClass | Namespace | Wave | Notes |
|---------|--------------|-----------|------|-------|
| **Envoy Gateway** | `envoy` | envoy-gateway-system | 41 | Implémentation de référence |
| Istio Gateway | `istio` | istio-system | 45 | Requiert service mesh |
| NGINX Gateway Fabric | `nginx-gwf` | nginx-gateway | 41 | NGINX natif |
| APISIX | `apisix` | apisix | 65 | API Gateway complet |
| Traefik | `traefik` | traefik | 40 | Ingress + Gateway API |

Chaque Gateway utilise une GatewayClass distincte, permettant de router le trafic vers l'implémentation souhaitée.

## Cilium Network Policies

### Policies déployées automatiquement

Quand `features.cilium.ingressPolicy.enabled` ou `features.cilium.defaultDenyPodIngress.enabled`:

1. **cilium-host-ingress-policy.yaml**: Autorise le trafic externe (80/443) vers les nodes
2. **cilium-ingress-policy.yaml**: Autorise le trafic vers les pods envoy-gateway

### Policy ArgoCD (bootstrap)

Le script `deploy-applicationsets.sh` applique automatiquement `cilium-ingress-policy-envoy-gateway.yaml` pour autoriser l'accès à ArgoCD depuis le namespace `envoy-gateway-system`.

## Troubleshooting

### Gateway not ready

```bash
# Vérifier les events
kubectl describe gateway -n envoy-gateway-system default-gateway

# Vérifier les logs du contrôleur
kubectl logs -n envoy-gateway-system deployment/envoy-gateway --tail=100

# Vérifier que la GatewayClass existe
kubectl get gatewayclass envoy -o yaml
```

### HTTPRoute not routing traffic

```bash
# Vérifier le status de la HTTPRoute
kubectl get httproute -n <namespace> <route-name> -o yaml

# Vérifier les parents acceptés
kubectl describe httproute -n <namespace> <route-name>

# Vérifier les logs du proxy Envoy
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=default-gateway
```

### No LoadBalancer IP assigned

```bash
# Vérifier MetalLB
kubectl get pods -n metallb-system

# Vérifier les IPAddressPools
kubectl get ipaddresspool -n metallb-system

# Vérifier les events du service
kubectl describe svc -n envoy-gateway-system
```

### Certificate not ready

```bash
# Vérifier le certificat
kubectl describe certificate -n envoy-gateway-system wildcard-k8s-local

# Vérifier cert-manager
kubectl get pods -n cert-manager
kubectl logs -n cert-manager deployment/cert-manager --tail=50
```

### Metrics not available

```bash
# Vérifier que le port metrics est exposé
kubectl get svc -n envoy-gateway-system -o yaml | grep 19001

# Tester directement le pod
kubectl exec -n envoy-gateway-system deployment/envoy-gateway -- curl localhost:19001/metrics
```

## Migration depuis un autre provider

Pour migrer depuis Istio, NGINX Gateway Fabric ou autre:

1. **Changer le provider** dans `config/config.yaml`:
   ```yaml
   gatewayAPI:
     controller:
       provider: "envoy-gateway"
   ```

2. **Redéployer les ApplicationSets**:
   ```bash
   cd deploy/argocd && ./deploy-applicationsets.sh
   ```

3. **Vérifier le déploiement** de la nouvelle Gateway

4. **Migrer les HTTPRoutes** progressivement (elles continueront à fonctionner si les hostnames correspondent)

5. **Supprimer l'ancien provider** si nécessaire (désactiver dans config)

## References

- **Official Docs**: https://gateway.envoyproxy.io/docs/
- **Installation Guide**: https://gateway.envoyproxy.io/docs/install/gateway-helm-api/
- **Gateway API Spec**: https://gateway-api.sigs.k8s.io/
- **GitHub**: https://github.com/envoyproxy/gateway
- **Releases**: https://github.com/envoyproxy/gateway/releases
- **Helm Chart**: https://github.com/envoyproxy/gateway/tree/main/charts/gateway-helm

## Sync Wave

**** - Deploy after Gateway API CRDs, alongside other Gateway implementations.

Dependencies:
- MetalLB - LoadBalancer provider
- Gateway API Controller - CRDs
- Cert-Manager - TLS certificates
