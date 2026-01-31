# OAuth2 Proxy - OIDC Authentication

OAuth2 Proxy fournit une authentification OIDC centralisée via Keycloak pour les applications sans auth native.

## ⚠️ Sécurité - Déploiement Atomique (Fail-Close)

### Risque identifié

Lors du démarrage du cluster, une **race condition** peut exposer les applications sans authentification :

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PROBLÈME : Sources ArgoCD séparées                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Source 1: HTTPRoute          Source 2: SnippetsFilter/AuthPolicy           │
│  ┌──────────────────┐         ┌──────────────────────────────┐              │
│  │ prometheus route │  ───X───│ oauth2-auth SnippetsFilter   │              │
│  │ (créé avec       │         │ (ÉCHOUE si CRD manquant)     │              │
│  │  extensionRef)   │         └──────────────────────────────┘              │
│  └──────────────────┘                                                       │
│          │                                                                  │
│          ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ VULNÉRABILITÉ: HTTPRoute créé SANS protection OAuth2 !              │   │
│  │ → Application accessible sans authentification                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Scénario de vulnérabilité** :
1. Le cluster démarre, ArgoCD synchronise les applications
2. L'HTTPRoute est créé (source 1 réussit)
3. Le SnippetsFilter/AuthorizationPolicy échoue car le CRD n'existe pas encore (nginx-gateway-fabric/istio pas prêt)
4. **L'HTTPRoute existe sans protection** → accès non authentifié possible
5. Plus tard, quand le CRD est disponible, la ressource OAuth2 est créée
6. L'application est finalement protégée, mais une fenêtre de vulnérabilité a existé

### Solution : Déploiement Atomique

Toutes les ressources (HTTPRoute + OAuth2) sont dans le **même source Kustomize** :

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SOLUTION : Source unique (atomique)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Source unique: httproute-oauth2-{provider}/                                │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ kustomization.yaml                                                   │   │
│  │ ├── resources:                                                       │   │
│  │ │   ├── ../httproute              (HTTPRoutes base)                  │   │
│  │ │   ├── snippetsfilter.yaml       (OAuth2 auth)                      │   │
│  │ │   └── referencegrant.yaml       (permissions)                      │   │
│  │ └── patches:                                                         │   │
│  │     └── extensionRef → oauth2-auth                                   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│          │                                                                  │
│          ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │ SÉCURISÉ: Si CRD manquant → TOUT le source échoue                   │   │
│  │ → Aucune route non protégée ne peut être créée                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Comportement par provider

| Provider | Ressource Auth | Comportement si CRD manquant | Pattern utilisé |
|----------|----------------|------------------------------|-----------------|
| **nginx-gwf** | `SnippetsFilter` | ❌ Fail-open (route sans auth) | `httproute-oauth2-nginx-gwf/` |
| **istio** | `AuthorizationPolicy` | ❌ Fail-open (route sans auth) | `httproute-oauth2-istio/` |
| **envoy-gateway** | `SecurityPolicy` | ❌ Fail-open (route sans auth) | `httproute-oauth2-envoy-gateway/` |
| **traefik** | `Middleware` | ✅ Fail-close (routing échoue) | Sources séparées OK |
| **apisix** | Plugin inline | ✅ Intégré dans ApisixRoute | N/A (déjà atomique) |

### Applications protégées par déploiement atomique

| Application | nginx-gwf | istio | envoy-gateway |
|-------------|-----------|-------|---------------|
| prometheus-stack | `httproute-oauth2-nginx-gwf/` | `httproute-oauth2-istio/` | `httproute-oauth2-envoy-gateway/` |
| cilium (hubble) | `httproute-oauth2-nginx-gwf/` | Via istio app | `httproute-oauth2-envoy-gateway/` |
| oauth2-proxy | `httproute-nginx-gwf/` | N/A | N/A |
| jaeger | N/A | `httproute-oauth2-istio/` | `httproute-oauth2-envoy-gateway/` |
| longhorn | N/A | `httproute-oauth2-istio/` | `httproute-oauth2-envoy-gateway/` |

### Mesures de sécurité supplémentaires

1. **SnippetsFilter Fail-Close** : Configuration `error_page 500 502 503 504 = /oauth2/unavailable` retourne 503 si OAuth2 Proxy est indisponible (pas de bypass)

2. **Timeouts courts** : `proxy_connect_timeout 5s; proxy_read_timeout 10s` pour détecter rapidement l'indisponibilité

3. **ArgoCD Sync Retry** : Retry automatique avec backoff exponentiel jusqu'à ce que toutes les ressources soient créées

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

- **Keycloak** : Fournit l'IdP OIDC
 - Client `oauth2-proxy` créé automatiquement
 - Realm `k8s` avec utilisateurs/groupes

- **Gateway Controller** (selon provider) :
 - **Istio** : Service mesh avec ext_authz
   - ExtensionProvider `oauth2-proxy` configuré dans le mesh
 - **nginx-gateway-fabric** : Gateway API avec SnippetsFilter
   - SnippetsFilter `oauth2-auth` déployé dans le namespace gateway
 - **APISIX** : API Gateway avec forward-auth plugin
   - Plugin `forward-auth` + `serverless-post-function` configuré par route

- **Cert-Manager** : Certificats TLS

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
    enabled: true  # 
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

> ⚠️ **IMPORTANT** : Utilisez le pattern de déploiement atomique pour éviter les vulnérabilités de race condition (voir section Sécurité ci-dessus).

### Pattern Atomique (Recommandé)

Pour tous les providers sauf Traefik et APISIX, créez un overlay combiné `httproute-oauth2-{provider}/` :

#### 1. Créer l'overlay atomique

```bash
mkdir -p apps/<app>/kustomize/httproute-oauth2-{istio,nginx-gwf,envoy-gateway}
```

#### 2. Structure du répertoire

```
apps/<app>/kustomize/
├── httproute/                          # HTTPRoutes de base
│   ├── kustomization.yaml
│   └── httproute.yaml
├── httproute-oauth2-istio/             # Atomique: HTTPRoute + AuthorizationPolicy
│   ├── kustomization.yaml
│   └── authorization-policy.yaml
├── httproute-oauth2-nginx-gwf/         # Atomique: HTTPRoute + SnippetsFilter
│   ├── kustomization.yaml
│   ├── snippetsfilter.yaml
│   └── referencegrant.yaml
└── httproute-oauth2-envoy-gateway/     # Atomique: HTTPRoute + SecurityPolicy
    ├── kustomization.yaml
    ├── security-policy.yaml
    ├── backend-keycloak.yaml
    └── oidc-secret.yaml
```

#### 3. Exemple kustomization.yaml (Istio)

```yaml
---
# httproute-oauth2-istio/kustomization.yaml
# SECURITY: All resources in same source = atomic deployment
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../httproute                    # Base HTTPRoutes
  - authorization-policy.yaml       # OAuth2 AuthorizationPolicy
```

#### 4. ApplicationSet avec conditions atomiques

```yaml
{{- if .features.gatewayAPI.httpRoute.enabled }}
{{- if and .features.oauth2Proxy.enabled (eq .features.gatewayAPI.controller.provider "istio") }}
# Source: HTTPRoute + OAuth2 AuthorizationPolicy for Istio (atomic deployment)
# SECURITY: HTTPRoutes and AuthorizationPolicy in same source = fail together if CRD missing
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/httproute-oauth2-istio
  kustomize:
    patches:
      - target:
          kind: HTTPRoute
          name: <app>
        patch: |
          - op: replace
            path: /spec/hostnames/0
            value: <app>.{{ .common.domain }}
      - target:
          kind: AuthorizationPolicy
          name: oauth2-proxy-<app>
        patch: |
          - op: replace
            path: /spec/rules/0/to/0/operation/hosts/0
            value: <app>.{{ .common.domain }}
{{- else if and .features.oauth2Proxy.enabled (eq .features.gatewayAPI.controller.provider "nginx-gwf") }}
# Source: HTTPRoute + OAuth2 SnippetsFilter for nginx-gwf (atomic deployment)
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/httproute-oauth2-nginx-gwf
  kustomize:
    patches:
      - target:
          kind: HTTPRoute
          name: <app>
        patch: |
          - op: replace
            path: /spec/hostnames/0
            value: <app>.{{ .common.domain }}
{{- else if and .features.oauth2Proxy.enabled (eq .features.gatewayAPI.controller.provider "envoy-gateway") }}
# Source: HTTPRoute + OAuth2 SecurityPolicy for Envoy Gateway (atomic deployment)
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/httproute-oauth2-envoy-gateway
  kustomize:
    patches:
      # ... patches pour HTTPRoute, SecurityPolicy, Backend ...
{{- else }}
# Source: HTTPRoute standard (sans OAuth2 ou provider non supporté)
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/httproute
{{- end }}
{{- end }}
```

### Pattern Traefik (Fail-Close natif)

Traefik peut utiliser des sources séparées car il refuse le routage si le Middleware n'existe pas :

```yaml
# HTTPRoute avec extensionRef inline
- target:
    kind: HTTPRoute
    name: <app>
  patch: |
    - op: add
      path: /spec/rules/0/filters
      value:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: oauth2-proxy-auth

# Source séparée pour le Middleware (OK car fail-close)
{{- if and .features.oauth2Proxy.enabled (eq .features.gatewayAPI.controller.provider "traefik") }}
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app>/kustomize/oauth2-authz-traefik
{{- end }}
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
