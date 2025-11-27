# Keycloak

Keycloak est deploye via l'operateur Keycloak officiel avec une base PostgreSQL geree par CloudNativePG.

## Architecture OIDC

### Realm gigix

Le realm `gigix` est configure via le CR `KeycloakRealmImport` et contient:

- **Roles**: `admin`, `developer`, `readonly`
- **Groupes**: `admins`, `developers`, `readonly` (avec mapping vers les roles)
- **Client scope**: `groups` pour inclure les groupes dans les tokens
- **Clients OIDC**: `argocd`, `grafana`
- **Utilisateur admin**: cree via GitOps

### Gestion des secrets OIDC

#### Dev (approche simplifiee)

En dev, tous les secrets clients OIDC sont centralises dans un seul secret Kubernetes:

```
keycloak/secrets/dev/secret-oidc.yaml
```

Ce secret contient:
- `argocd-client-secret`: Secret du client ArgoCD
- `grafana-client-secret`: Secret du client Grafana
- `admin-password`: Mot de passe admin du realm

**Avantages**:
- Configuration simple et rapide
- Un seul fichier a gerer
- Ideal pour le developpement et les tests

#### Prod (approche recommandee)

En production, il est **fortement recommande** de separer les secrets par application:

```
keycloak/secrets/prod/
├── secret-argocd.yaml      # Secret client ArgoCD uniquement
├── secret-grafana.yaml     # Secret client Grafana uniquement
└── secret-admin.yaml       # Credentials admin realm
```

**Avantages**:
- **Principe du moindre privilege**: Chaque application n'a acces qu'a son propre secret
- **Rotation independante**: Possibilite de changer un secret sans impacter les autres
- **Audit**: Meilleure tracabilite des acces aux secrets
- **Securite**: Compromission d'une application n'expose pas les autres secrets

**Implementation prod**:

1. Creer des secrets separes:
```yaml
# secret-argocd.yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-argocd-client
  namespace: keycloak
stringData:
  client-secret: "<secret-unique-argocd>"
```

2. Modifier le `KeycloakRealmImport` pour referencer chaque secret:
```yaml
placeholders:
  ARGOCD_CLIENT_SECRET:
    secret:
      name: keycloak-argocd-client
      key: client-secret
```

3. Mettre a jour le `ksops-generator.yaml`:
```yaml
files:
  - ./secret-argocd.yaml
  - ./secret-grafana.yaml
  - ./secret-admin.yaml
```

## URLs

| Service | URL |
|---------|-----|
| Keycloak Console | https://keycloak.gigix |
| Realm gigix | https://keycloak.gigix/realms/gigix |
| OIDC Discovery | https://keycloak.gigix/realms/gigix/.well-known/openid-configuration |

## Applications integrees

| Application | Client ID | Callback URL |
|-------------|-----------|--------------|
| ArgoCD | `argocd` | https://argocd.gigix/auth/callback |
| Grafana | `grafana` | https://grafana.gigix/login/generic_oauth |
