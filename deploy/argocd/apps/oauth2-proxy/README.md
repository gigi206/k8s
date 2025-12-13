# OAuth2 Proxy - OIDC Authentication

OAuth2 Proxy fournit une authentification OIDC centralisée via Keycloak pour les applications sans auth native.

## Architecture

OAuth2 Proxy est utilisé en mode **ext_authz** avec Istio :
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

## Dépendances

### Automatiques (via ApplicationSets)

- **Keycloak** (Wave 80) : Fournit l'IdP OIDC
  - Client `oauth2-proxy` créé automatiquement
  - Realm `k8s` avec utilisateurs/groupes

- **Istio** (Wave 40) : Service mesh avec ext_authz
  - ExtensionProvider `oauth2-proxy` configuré dans le mesh

- **Cert-Manager** (Wave 20) : Certificats TLS

### Applications protégées

Chaque application gère sa propre `AuthorizationPolicy` dans son dossier `oauth2-authz/` :

| Application | AuthorizationPolicy | Condition |
|-------------|---------------------|-----------|
| prometheus-stack | `oauth2-proxy-prometheus`, `oauth2-proxy-alertmanager` | `features.oauth2Proxy.enabled` |
| cilium-monitoring | `oauth2-proxy-hubble` | `features.oauth2Proxy.enabled` |
| longhorn | `oauth2-proxy-longhorn` | `features.oauth2Proxy.enabled` |

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

1. Créer `apps/<app>/oauth2-authz/kustomization.yaml` :
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - authorization-policy.yaml
```

2. Créer `apps/<app>/oauth2-authz/authorization-policy.yaml` :
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
  path: deploy/argocd/apps/<app>/oauth2-authz
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
