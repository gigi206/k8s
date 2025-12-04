# Troubleshooting: Istio 1.28.0 + Kubernetes Ingress + HTTPS

## Problème

Après migration d'Istio 1.18.2 vers Istio 1.28.0 (Ambient mode), les Kubernetes Ingress ne fonctionnent plus en HTTPS:
- ✅ HTTP fonctionne (redirection 307 vers HTTPS)
- ❌ HTTPS échoue (connexion reset: `curl: (35) Recv failure: Connexion ré-initialisée`)

## Diagnostic

### Configuration Actuelle

**Istio 1.28.0 (Ambient mode)**:
```yaml
# deploy/argocd/apps/istio/config/dev.yaml
meshConfig:
  ingressControllerMode: DEFAULT
  ingressClass: istio
  ingressService: istio-ingressgateway
  ingressSelector: ingressgateway
```

**Istio Ingress Gateway**:
- Déployé via Helm chart `gateway` version 1.28.0
- DaemonSet dans namespace `istio-system`
- LoadBalancer IP: 192.168.121.241

**Ingress Kubernetes**:
```yaml
# Exemple: deploy/argocd/apps/cilium-monitoring/kustomize/hubble-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system  # ⚠️ Namespace différent
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
spec:
  ingressClassName: istio
  rules:
  - host: hubble.k8s.lan
    http:
      paths:
      - backend:
          service:
            name: hubble-ui
            port:
              name: http
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - hubble.k8s.lan
    secretName: hubble-ui-tls  # ⚠️ Secret dans kube-system
```

**Certificats TLS**:
- Créés automatiquement par cert-manager via l'annotation Ingress
- Stockés dans le namespace de l'Ingress (kube-system, monitoring, argo-cd, etc.)

### Cause Racine Identifiée

**Istio Ingress Gateway ne peut PAS lire les secrets TLS cross-namespace.**

C'est une limitation documentée d'Istio:
- [Issue #14598](https://github.com/istio/istio/issues/14598) - Allow Ingress gateway SDS to search all namespaces for certificate secrets
- [Issue #27740](https://github.com/istio/istio/issues/27740) - Ingressgateway searches for TLS secret in the wrong namespace
- [Issue #25018](https://github.com/istio/istio/issues/25018) - Can't reference a secret from a different namespace

**Comportement constaté**:
```bash
# Secrets TLS créés par cert-manager dans différents namespaces
$ kubectl get certificates -A
NAMESPACE         NAME                    READY   SECRET
argo-cd           argocd-server-tls       True    argocd-server-tls
kube-system       hubble-ui-tls           True    hubble-ui-tls
longhorn-system   longhorn-cert-tls       True    longhorn-cert-tls
monitoring        alertmanager-cert-tls   True    alertmanager-cert-tls
monitoring        grafana-cert-tls        True    grafana-cert-tls
monitoring        prometheus-cert-tls     True    prometheus-cert-tls
istio-system      wildcard-k8s-local          True    wildcard-k8s-local-tls

# Istio Ingress Gateway dans istio-system ne peut lire que:
$ kubectl get secret -n istio-system | grep tls
wildcard-k8s-local-tls    kubernetes.io/tls    3      10m
# ⚠️ Les secrets hubble-ui-tls, grafana-cert-tls, etc. sont inaccessibles
```

L'Istio Ingress Gateway agent s'exécute dans le namespace `istio-system` et ne peut lire que les secrets de ce namespace. Quand un Ingress dans `kube-system` référence `hubble-ui-tls`, Istio cherche ce secret dans `istio-system` et ne le trouve pas.

**Citation de la documentation officielle**:
> "the referenced Secret must exist in the namespace of the istio-ingressgateway deployment (typically istio-system)"

### Différence avec Istio 1.18.2

Dans l'ancienne configuration:
```yaml
# https://github.com/gigi206/k8s/blob/main/argocd/istio-ingress/istio-ingress.yaml
destination:
  namespace: istio-ingress  # Namespace dédié pour l'Ingress Gateway
```

- Istio Ingress Gateway était dans `istio-ingress`
- Les Ingress et secrets TLS étaient probablement aussi dans `istio-ingress`
- Tout dans le même namespace → ça fonctionnait ✅

Dans la nouvelle configuration:
- Istio Ingress Gateway dans `istio-system`
- Ingress éparpillés dans `kube-system`, `monitoring`, `argo-cd`, `longhorn-system`
- Secrets TLS créés par cert-manager dans le namespace de chaque Ingress
- Cross-namespace access impossible → ça ne fonctionne pas ❌

## Solutions Possibles

### Option 1: Utiliser le Wildcard Certificate (Recommandé Simple)

**Avantage**: Un seul certificat pour tous les sous-domaines `*.k8s.lan`
**Inconvénient**: Tous les services partagent le même certificat

Le certificat wildcard `wildcard-k8s-local-tls` existe déjà dans `istio-system`.

**Modification requise**: Supprimer les sections `tls` des Ingress pour ne plus créer de certificats individuels.

**Avant**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer  # Crée un cert
spec:
  ingressClassName: istio
  tls:
  - hosts:
    - hubble.k8s.lan
    secretName: hubble-ui-tls  # Créé dans kube-system (inaccessible)
  rules:
  - host: hubble.k8s.lan
    # ...
```

**Après**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system
  # ⚠️ Pas d'annotation cert-manager
spec:
  ingressClassName: istio
  # ⚠️ Pas de section tls (utilise le wildcard du Gateway)
  rules:
  - host: hubble.k8s.lan
    # ...
```

Le Gateway Istio gère le TLS avec le wildcard:
```yaml
# deploy/argocd/apps/istio-gateway/resources/gateway.yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      protocol: HTTPS
    hosts:
    - "*"
    tls:
      mode: SIMPLE
      credentialName: wildcard-k8s-local-tls  # ✅ Accessible dans istio-system
```

### Option 2: Synchroniser les Secrets avec Kubernetes Reflector

**Avantage**: Chaque service garde son propre certificat
**Inconvénient**: Dépendance supplémentaire (Reflector)

[Kubernetes Reflector](https://github.com/emberstack/kubernetes-reflector) synchronise automatiquement les secrets entre namespaces.

**Installation**:
```bash
helm repo add emberstack https://emberstack.github.io/helm-charts
helm install reflector emberstack/reflector -n kube-system
```

**Configuration cert-manager Certificate**:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: hubble-ui-tls
  namespace: kube-system
spec:
  secretName: hubble-ui-tls
  issuerRef:
    name: selfsigned-cluster-issuer
    kind: ClusterIssuer
  dnsNames:
    - hubble.k8s.lan
  secretTemplate:
    annotations:
      # Reflector copie automatiquement vers istio-system
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "istio-system"
```

**Résultat**: Le secret `hubble-ui-tls` est copié automatiquement dans `istio-system`.

**Documentation**: [cert-manager - Syncing Secrets Across Namespaces](https://cert-manager.io/docs/devops-tips/syncing-secrets-across-namespaces/)

### Option 3: Copier Manuellement les Secrets (Workaround Temporaire)

```bash
# Pour chaque Ingress, copier son secret vers istio-system
for ns in kube-system monitoring argo-cd longhorn-system; do
  for secret in $(kubectl get secret -n $ns -o name | grep '\-tls$'); do
    kubectl get $secret -n $ns -o yaml | \
      sed "s/namespace: $ns/namespace: istio-system/" | \
      kubectl apply -f -
  done
done
```

**Inconvénient**: Pas de synchronisation automatique lors du renouvellement des certificats.

### Option 4: Migrer vers Kubernetes Gateway API + HTTPRoute (Recommandé Long Terme)

**Avantage**: Architecture moderne, meilleur support d'Istio 1.28 Ambient
**Inconvénient**: Refactoring important

Le **Kubernetes Gateway API** supporte les références cross-namespace via **ReferenceGrant**.

**Avant (Kubernetes Ingress)**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  ingressClassName: istio
  rules:
  - host: hubble.k8s.lan
    http:
      paths:
      - backend:
          service:
            name: hubble-ui
            port:
              name: http
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - hubble.k8s.lan
    secretName: hubble-ui-tls
```

**Après (Gateway API)**:
```yaml
# HTTPRoute remplace Ingress
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  parentRefs:
  - name: istio-ingressgateway
    namespace: istio-system
    kind: Gateway
  hostnames:
  - "hubble.k8s.lan"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: hubble-ui
      port: 80

---
# ReferenceGrant autorise Gateway à lire le secret cross-namespace
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-istio-gateway-secrets
  namespace: kube-system
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: istio-system
  to:
  - group: ""
    kind: Secret
```

**Documentation**:
- [Istio Gateway API](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Kubernetes Gateway API ReferenceGrant](https://gateway-api.sigs.k8s.io/api-types/referencegrant/)

### Option 5: Déployer Ingress Gateway dans Chaque Namespace

**Avantage**: Isolation complète par namespace
**Inconvénient**: Multiplication des ressources (1 LoadBalancer par namespace)

```yaml
# Déployer un Ingress Gateway dédié dans kube-system
helm install istio-ingressgateway-kube-system istio/gateway \
  --namespace kube-system \
  --set name=istio-ingressgateway-kube-system
```

Pas recommandé sauf pour des environnements multi-tenant avec isolation stricte.

## Comparaison des Solutions

| Solution | Complexité | Certificats Individuels | Renouvellement Auto | Coût Maintenance |
|----------|------------|-------------------------|---------------------|------------------|
| Wildcard Certificate | ⭐ Faible | ❌ Non | ✅ Oui | ⭐ Faible |
| Reflector | ⭐⭐ Moyen | ✅ Oui | ✅ Oui | ⭐⭐ Moyen |
| Copie Manuelle | ⭐ Faible | ✅ Oui | ❌ Non | ⭐⭐⭐ Élevé |
| Gateway API | ⭐⭐⭐ Élevé | ✅ Oui | ✅ Oui | ⭐⭐ Moyen |
| Gateway par NS | ⭐⭐⭐ Élevé | ✅ Oui | ✅ Oui | ⭐⭐⭐ Élevé |

## Recommandation

**Pour le projet actuel (dev)**:
1. **Court terme**: Utiliser le wildcard certificate (Option 1)
   - Simple à implémenter
   - Aucune dépendance supplémentaire
   - Adapté pour un environnement dev avec domaine unique (k8s.lan)

2. **Moyen terme**: Migrer vers Gateway API (Option 4)
   - Recommandé par Istio pour Ambient mode
   - Meilleur support long terme
   - Standard Kubernetes

**Pour la production**: Envisager Reflector (Option 2) ou Gateway API (Option 4) selon les besoins de sécurité et d'isolation des certificats.

## Ressources

- [Istio Issue #14598 - Allow Ingress gateway SDS to search all namespaces](https://github.com/istio/istio/issues/14598)
- [Istio Issue #27740 - Ingressgateway searches for TLS secret in the wrong namespace](https://github.com/istio/istio/issues/27740)
- [Istio Secure Gateways Documentation](https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/)
- [cert-manager - Syncing Secrets Across Namespaces](https://cert-manager.io/docs/devops-tips/syncing-secrets-across-namespaces/)
- [Kubernetes Reflector GitHub](https://github.com/emberstack/kubernetes-reflector)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [Istio Gateway API Documentation](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)

## Historique

- **2025-11-21**: Investigation initiale après migration Istio 1.18.2 → 1.28.0
- **Issue**: HTTPS ne fonctionne pas avec Kubernetes Ingress (connexion reset)
- **Cause**: Secrets TLS cross-namespace inaccessibles par Istio Ingress Gateway
- **Solutions**: 5 options identifiées, wildcard certificate recommandé pour dev
