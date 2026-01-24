# OAuth2 Proxy - OIDC Authentication

OAuth2 Proxy fournit une authentification OIDC centralisée via Keycloak pour les applications sans auth native.

## Architecture

OAuth2 Proxy supporte plusieurs modes selon le Gateway API controller utilisé :

### Mode ext_authz (Istio)

Utilisé avec Istio via `AuthorizationPolicy` :
- **Authentification seulement** : ne proxifie pas le trafic
- **Istio Gateway** : intercepte les requêtes et délègue l'auth à OAuth2 Proxy
- **AuthorizationPolicy** : chaque application gère sa propre policy (pattern décentralisé)

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│   Client    │────▶│ Istio Gateway│────▶│ OAuth2 Proxy    │
└─────────────┘     │ (ext_authz)  │     │ (auth check)    │
                    └──────────────┘     └─────────────────┘
                           │                      │
                           │ ◀── 200 OK ──────────┘
                           ▼
                    ┌──────────────┐
                    │  Backend App │
                    │ (prometheus) │
                    └──────────────┘
```

### Mode auth_request (nginx-gateway-fabric)

Utilisé avec nginx-gateway-fabric via `SnippetsFilter` :
- **Directive NGINX native** : `auth_request` pour l'authentification
- **SnippetsFilter** : injecte la configuration NGINX dans le Gateway
- **HTTPRoute filter** : chaque application référence le SnippetsFilter partagé

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

> **Note** : nginx-gateway-fabric n'a pas de support ext_authz natif (prévu v2.7.0). Le SnippetsFilter est utilisé comme workaround.

### Mode forward-auth (APISIX)

Utilisé avec APISIX via le plugin `forward-auth` :
- **Plugin natif APISIX** : `forward-auth` pour valider les sessions
- **ApisixUpstream** : accès cross-namespace à oauth2-proxy
- **serverless-post-function** : convertit les réponses 401 en redirections 302

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Client    │────▶│ APISIX Gateway   │────▶│ OAuth2 Proxy    │
└─────────────┘     │ (forward-auth)   │     │ (auth check)    │
                    └──────────────────┘     └─────────────────┘
                           │                      │
                           │ ◀── 200 OK ──────────┘
                           ▼
                    ┌──────────────┐
                    │  Backend App │
                    │ (prometheus) │
                    └──────────────┘
```

> **Voir** : Documentation complète dans `apps/apisix/README.md` section "OAuth2 Authentication".

### Mode forwardAuth (Traefik)

Utilisé avec Traefik via le middleware `forwardAuth` :
- **Middleware forwardAuth** : délègue l'authentification à OAuth2 Proxy
- **Service nginx intermédiaire** : convertit les 401 en redirections 302
- **Middleware chain** : forwardAuth → application

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Client    │────▶│ Traefik Gateway  │────▶│ nginx-unprivileged────▶│ OAuth2 Proxy    │
└─────────────┘     │ (forwardAuth)    │     │ (401→302 convert)│     │ (auth check)    │
                    └──────────────────┘     └─────────────────┘     └─────────────────┘
                           │                      │
                           │ ◀── 200 OK ──────────┘
                           ▼                  ou 302 redirect
                    ┌──────────────┐
                    │  Backend App │
                    │ (prometheus) │
                    └──────────────┘
```

#### Pourquoi un nginx intermédiaire ?

**Limitation Traefik** : Le middleware `forwardAuth` retourne le code HTTP reçu directement au client.
Quand oauth2-proxy retourne 401 (non authentifié), Traefik passe ce 401 au navigateur au lieu de rediriger vers la page de login.

**Comportement oauth2-proxy** : L'endpoint `/oauth2/auth` est conçu pour `auth_request` nginx et retourne :
- `202 Accepted` si authentifié
- `401 Unauthorized` si non authentifié (sans redirection)

**Solution** : Le service `oauth2-auth-redirect` (nginx-unprivileged) :
1. Proxifie les requêtes vers oauth2-proxy `/oauth2/auth`
2. Intercepte les réponses 401
3. Retourne une redirection 302 vers `/oauth2/start` pour initier le flow OAuth

#### Pourquoi Traefik est le seul à nécessiter nginx ?

| Provider | Mécanisme 401→302 | Service externe ? |
|----------|-------------------|-------------------|
| **Istio** | ext_authz natif | ❌ Non |
| **nginx-gwf** | `auth_request` natif | ❌ Non |
| **APISIX** | `serverless-post-function` plugin | ❌ Non (Lua intégré) |
| **Envoy Gateway** | ext_authz natif | ❌ Non |
| **Traefik** | nginx intermédiaire | ✅ **Oui** |

Les autres providers ont des mécanismes natifs ou des plugins intégrés pour gérer la conversion 401→302.
Traefik n'a pas cette fonctionnalité dans son middleware `forwardAuth`.

#### Alternatives évaluées

| Solution | Verdict |
|----------|---------|
| Traefik `errors` middleware (3.4+) | Nécessite toujours un service pour retourner la 302 |
| forwardAuth vers `/oauth2/` (racine) | Retourne aussi 401, pas de redirection |
| `traefik-forward-auth` | Projet alternatif dédié, moins de fonctionnalités qu'oauth2-proxy |

> **Référence** : [OAuth and Traefik 2024](https://farcaller.net/2024/oauth-and-traefik-how-to-protect-your-endpoints/)

## Dépendances

### Automatiques (via ApplicationSets)

- **Keycloak** (Wave 80) : Fournit l'IdP OIDC
  - Client `oauth2-proxy` créé automatiquement
  - Realm `k8s` avec utilisateurs/groupes

- **Gateway Controller** (selon provider) :
  - **Istio** (Wave 40) : Service mesh avec ext_authz
    - ExtensionProvider `oauth2-proxy` configuré dans le mesh
  - **nginx-gateway-fabric** (Wave 41) : Gateway API avec SnippetsFilter
    - SnippetsFilter `oauth2-auth` déployé dans le namespace gateway
  - **APISIX** (Wave 40) : API Gateway avec forward-auth plugin
    - Plugin `forward-auth` + `serverless-post-function` configuré par route

- **Cert-Manager** (Wave 20) : Certificats TLS

### Applications protégées

Chaque application gère sa propre configuration OAuth2 selon le provider :

**Avec Istio** (`oauth2-authz/`) :

| Application | AuthorizationPolicy | Condition |
|-------------|---------------------|-----------|
| prometheus-stack | `oauth2-proxy-prometheus`, `oauth2-proxy-alertmanager` | `features.oauth2Proxy.enabled` |
| cilium | `oauth2-proxy-hubble` | `features.oauth2Proxy.enabled` |
| longhorn | `oauth2-proxy-longhorn` | `features.oauth2Proxy.enabled` |

**Avec nginx-gateway-fabric** (`oauth2-authz-nginx-gwf/`) :

| Application | Ressources | Condition |
|-------------|------------|-----------|
| prometheus-stack | ReferenceGrant, HTTPRoute patches | `features.oauth2Proxy.enabled` + provider `nginx-gwf` |
| cilium | ReferenceGrant, HTTPRoute patches | `features.oauth2Proxy.enabled` + provider `nginx-gwf` |

**Avec APISIX** (`apisix/`) :

| Application | Ressources | Condition |
|-------------|------------|-----------|
| prometheus-stack | ApisixUpstream, ApisixRoute avec plugins | `features.oauth2Proxy.enabled` + provider `apisix` |
| cilium | ApisixUpstream, ApisixRoute avec plugins | `features.oauth2Proxy.enabled` + provider `apisix` |
| longhorn | ApisixUpstream, ApisixRoute avec plugins | `features.oauth2Proxy.enabled` + provider `apisix` |
| jaeger | ApisixUpstream, ApisixRoute avec plugins | `features.oauth2Proxy.enabled` + provider `apisix` |
| istio (kiali) | ApisixUpstream, ApisixRoute avec plugins | `features.oauth2Proxy.enabled` + provider `apisix` |

> **Voir** : Configuration détaillée dans `apps/apisix/README.md` section "OAuth2 Authentication".

## Configuration

### Feature Flag

```yaml
# config/config.yaml
features:
  oauth2Proxy:
    enabled: true  # Wave 81
```

### Environnements

**Dev (`config/dev.yaml`):**
- 1 replica
- Skip SSL verification (self-signed certs)
- Auto-sync activé

**Prod (`config/prod.yaml`):**
- 2+ replicas (HA)
- SSL verification activé
- Auto-sync désactivé

### Secrets (KSOPS)

Les secrets OIDC sont chiffrés avec SOPS dans `secrets/{env}/` :

```yaml
# secrets/dev/secret.yaml (chiffré)
apiVersion: v1
kind: Secret
metadata:
  name: oauth2-proxy-secrets
  namespace: oauth2-proxy
stringData:
  client-id: oauth2-proxy
  client-secret: <secret>
  cookie-secret: <32-bytes-base64>
```

Générer un cookie-secret :
```bash
openssl rand -base64 32 | tr -d '\n'
```

## Fonctionnement

### Flow d'authentification

1. Client accède à `prometheus.k8s.lan`
2. Istio Gateway intercepte (AuthorizationPolicy)
3. ext_authz appelle OAuth2 Proxy
4. Si non authentifié → redirect vers Keycloak
5. Utilisateur s'authentifie sur Keycloak
6. Callback vers `oauth2.k8s.lan/oauth2/callback`
7. Cookie `_oauth2_proxy` créé (domaine `.k8s.lan`)
8. Redirect vers l'app originale
9. Requêtes suivantes : cookie validé par OAuth2 Proxy

### Cookie partagé

Le cookie utilise le domaine parent (`.k8s.lan`) pour le SSO :
- Une seule authentification pour toutes les apps
- Cookie valide 7 jours, refresh toutes les heures

## Ajouter une nouvelle application protégée

### Avec Istio (AuthorizationPolicy)

1. Créer `apps/<app>/kustomize/oauth2-authz/kustomization.yaml` :
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - authorization-policy.yaml
```

2. Créer `apps/<app>/kustomize/oauth2-authz/authorization-policy.yaml` :
```yaml
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: oauth2-proxy-<app>
  namespace: istio-system
spec:
  targetRef:
    kind: Gateway
    group: gateway.networking.k8s.io
    name: istio-gateway
  action: CUSTOM
  provider:
    name: oauth2-proxy
  rules:
    - to:
        - operation:
            hosts:
              - "<app>.PLACEHOLDER.example.com"
```

3. Ajouter dans `apps/<app>/applicationset.yaml` (templatePatch) :
```yaml
{{- if .features.oauth2Proxy.enabled }}
# Source: AuthorizationPolicy for OAuth2 Proxy ext_authz
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/oauth2-authz
  kustomize:
    patches:
      - target:
          kind: AuthorizationPolicy
          name: oauth2-proxy-<app>
        patch: |
          - op: replace
            path: /spec/rules/0/to/0/operation/hosts/0
            value: <app>.{{ .common.domain }}
{{- end }}
```

### Avec nginx-gateway-fabric (SnippetsFilter)

1. Créer `apps/<app>/kustomize/oauth2-authz-nginx-gwf/kustomization.yaml` :
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - referencegrant.yaml
```

2. Créer `apps/<app>/kustomize/oauth2-authz-nginx-gwf/referencegrant.yaml` :
```yaml
---
# Permet aux HTTPRoutes de ce namespace de référencer le SnippetsFilter oauth2-auth
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-nginx-gateway-snippets
  namespace: nginx-gateway
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: <app-namespace>  # Namespace de l'application
  to:
    - group: gateway.nginx.org
      kind: SnippetsFilter
```

3. Ajouter le SnippetsFilter à l'HTTPRoute de l'application via un patch dans l'ApplicationSet :
```yaml
{{- if and .features.oauth2Proxy.enabled (eq .features.gatewayAPI.controller.provider "nginx-gwf") }}
# Source: ReferenceGrant for OAuth2 SnippetsFilter
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/oauth2-authz-nginx-gwf
{{- end }}
```

4. Modifier l'HTTPRoute pour ajouter le filter (via patch kustomize dans l'ApplicationSet) :
```yaml
# Dans la section kustomize.patches de l'HTTPRoute source :
- target:
    kind: HTTPRoute
    name: <app>
  patch: |
    - op: add
      path: /spec/rules/0/filters
      value:
        - type: ExtensionRef
          extensionRef:
            group: gateway.nginx.org
            kind: SnippetsFilter
            name: oauth2-auth
```

## Vérification

### Pods et services

```bash
# Pods OAuth2 Proxy
kubectl get pods -n oauth2-proxy

# Service
kubectl get svc -n oauth2-proxy

# Logs
kubectl logs -n oauth2-proxy deployment/oauth2-proxy
```

### Istio ExtensionProvider

```bash
# Vérifier la config mesh
kubectl get configmap istio -n istio-system -o yaml | grep -A10 oauth2-proxy
```

### nginx-gateway-fabric SnippetsFilter

```bash
# Vérifier le SnippetsFilter
kubectl get snippetsfilter -n nginx-gateway

# Vérifier les ReferenceGrants
kubectl get referencegrant -A | grep nginx-gateway

# Vérifier les HTTPRoutes avec le filter
kubectl get httproute -A -o yaml | grep -A5 "extensionRef"
```

### Test d'authentification

```bash
# Accéder à une app protégée
curl -I https://prometheus.k8s.lan

# Devrait retourner 302 redirect vers Keycloak
```

## Troubleshooting

### 403 Forbidden

**Cause** : AuthorizationPolicy mal configurée ou OAuth2 Proxy non accessible

**Vérifications** :
```bash
# AuthorizationPolicy existe ?
kubectl get authorizationpolicy -n istio-system | grep oauth2

# OAuth2 Proxy accessible depuis Istio ?
kubectl exec -n istio-system deploy/istiod -- curl -s http://oauth2-proxy.oauth2-proxy:4180/ping
```

### Redirect loop

**Cause** : Cookie domain incorrect ou CORS issues

**Vérifications** :
```bash
# Vérifier cookie domain dans les logs
kubectl logs -n oauth2-proxy deployment/oauth2-proxy | grep cookie

# Doit être: cookie-domain=".k8s.lan"
```

### Keycloak unreachable

**Cause** : OAuth2 Proxy démarre avant Keycloak

**Solution** : L'init container `wait-for-keycloak` attend que Keycloak soit ready

```bash
# Vérifier init container
kubectl describe pod -n oauth2-proxy -l app.kubernetes.io/name=oauth2-proxy
```

## Monitoring

Si `features.monitoring.enabled: true` :

- **ServiceMonitor** : Métriques OAuth2 Proxy
- **Métriques** : `oauth2_proxy_requests_total`, `oauth2_proxy_response_duration_seconds`

## Docs

- [OAuth2 Proxy Documentation](https://oauth2-proxy.github.io/oauth2-proxy/)
- [Istio ext_authz](https://istio.io/latest/docs/tasks/security/authorization/authz-custom/)
- [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/#_oidc)
