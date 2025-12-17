# Keycloak

Keycloak est deploye via l'operateur Keycloak officiel avec une base PostgreSQL geree par CloudNativePG.

## Overview

- **Wave**: 80
- **Namespace**: `keycloak`
- **Operator**: [Keycloak Operator](https://www.keycloak.org/guides#operator)
- **Database**: PostgreSQL via CloudNativePG

## Architecture OIDC

### Realm k8s

Le realm `k8s` est configure via le CR `KeycloakRealmImport` et contient:

- **Roles**: `admin`, `developer`, `readonly`
- **Groupes**: `admins`, `developers`, `readonly` (avec mapping vers les roles)
- **Client scope**: `groups` pour inclure les groupes dans les tokens
- **Clients OIDC**: `argocd`, `grafana`, `kiali`, `oauth2-proxy`
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

## Configuration

### Dev (config/dev.yaml)

```yaml
keycloak:
  operatorVersion: "26.2.4"
  instances: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
  database:
    instances: 1
    storage: 1Gi
```

### Prod (config/prod.yaml)

```yaml
keycloak:
  operatorVersion: "26.2.4"
  instances: 3  # HA
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 2Gi
  database:
    instances: 3  # HA PostgreSQL
    storage: 10Gi
```

## URLs

| Service | URL |
|---------|-----|
| Keycloak Console | https://keycloak.k8s.lan |
| Realm k8s | https://keycloak.k8s.lan/realms/k8s |
| OIDC Discovery | https://keycloak.k8s.lan/realms/k8s/.well-known/openid-configuration |

## Applications integrees

| Application | Client ID | Callback URL |
|-------------|-----------|--------------|
| ArgoCD | `argocd` | https://argocd.k8s.lan/auth/callback |
| Grafana | `grafana` | https://grafana.k8s.lan/login/generic_oauth |
| Kiali | `kiali` | https://kiali.k8s.lan |
| OAuth2-Proxy | `oauth2-proxy` | https://*.k8s.lan/oauth2/callback |

## Monitoring

### Prometheus Alerts

10 alertes sont configurees pour Keycloak et sa base de donnees :

**Keycloak Application**:

| Alerte | Severite | Description |
|--------|----------|-------------|
| KeycloakDown | critical | Tous les pods Keycloak indisponibles (5m) |
| KeycloakPodNotReady | high | Pod Keycloak non ready (5m) |
| KeycloakPodRestarting | high | Pod en restart loop (10m) |
| KeycloakHighMemoryUsage | warning | Utilisation memoire > 85% |

**Keycloak Operator**:

| Alerte | Severite | Description |
|--------|----------|-------------|
| KeycloakOperatorDown | critical | Operateur Keycloak indisponible (5m) |
| KeycloakOperatorPodRestarting | high | Operateur en restart loop (10m) |

**Base de donnees PostgreSQL (via CNPG)**:

| Alerte | Severite | Description |
|--------|----------|-------------|
| KeycloakDatabaseDown | critical | Cluster PostgreSQL indisponible (5m) |
| KeycloakDatabaseHighReplicationLag | high | Lag replication > 30s |
| KeycloakDatabaseStorageLow | warning | Stockage < 20% disponible |

### PodMonitor

Un PodMonitor est deploye pour collecter les metriques du cluster PostgreSQL keycloak-db.

### Metriques Prometheus

```promql
# Keycloak pods
kube_deployment_status_replicas_available{deployment="keycloak"}
kube_pod_status_ready{pod=~"keycloak-.*"}

# Database (via CNPG)
cnpg_collector_up{cluster="keycloak-db"}
cnpg_pg_replication_lag{cluster="keycloak-db"}
```

## Troubleshooting

### Keycloak ne demarre pas

```bash
# Verifier les pods
kubectl get pods -n keycloak

# Logs Keycloak
kubectl logs -n keycloak -l app=keycloak

# Events
kubectl get events -n keycloak --sort-by='.lastTimestamp'

# Verifier l'operateur
kubectl logs -n keycloak deployment/keycloak-operator
```

### Base de donnees PostgreSQL

```bash
# Status du cluster CNPG
kubectl get cluster -n keycloak keycloak-db

# Logs PostgreSQL
kubectl logs -n keycloak keycloak-db-1

# Connexion directe
kubectl exec -n keycloak keycloak-db-1 -- psql -U keycloak -d keycloak -c "SELECT version();"
```

### OIDC Login echoue

```bash
# Verifier le realm
kubectl get keycloakrealmimport -n keycloak

# Verifier les clients OIDC
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get clients -r k8s --server http://localhost:8080

# Logs d'authentification
kubectl logs -n keycloak -l app=keycloak | grep -i "login\|auth\|error"

# Tester le endpoint OIDC
curl -k https://keycloak.k8s.lan/realms/k8s/.well-known/openid-configuration | jq .
```

### Certificat TLS non reconnu

```bash
# Verifier le certificat
kubectl get certificate -n keycloak

# Status du certificat
kubectl describe certificate -n keycloak

# Verifier le secret TLS
kubectl get secret -n keycloak -l cert-manager.io/certificate-name
```

### Reset admin password

```bash
# Via le pod Keycloak
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh set-password \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --new-password "new-password"
```

## Dependencies

- **cnpg-operator** (Wave 65): Pour la base PostgreSQL
- **cert-manager** (Wave 20): Pour les certificats TLS
- **external-secrets** (Wave 25): Pour la synchronisation des secrets OIDC

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Keycloak Operator Guide](https://www.keycloak.org/guides#operator)
- [OIDC Configuration](https://www.keycloak.org/docs/latest/server_admin/#_oidc_clients)
- [CloudNativePG Integration](https://cloudnative-pg.io/documentation/)
