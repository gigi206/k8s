# Gateway API Controller

Gateway API Controller implémente les APIs Gateway standard de Kubernetes pour le routage et la gestion du trafic avancé.

## Dépendances

### Automatiques (via ApplicationSets)
Ces composants sont déployés automatiquement dans le bon ordre grâce aux sync waves:

Aucune dépendance automatique. Gateway API Controller s'installe de manière autonome.

### Manuelles

Aucune dépendance manuelle. Les CRDs Gateway API sont incluses dans le déploiement.

## Configuration

### Environnements

**Dev (`config-dev.yaml`):**
- CRD path: `config/crd/experimental` (Gateway API v1)
- Auto-sync activé

**Prod (`config-prod.yaml`):**
- CRD path: `config/crd/experimental` (Gateway API v1)
- Auto-sync désactivé (manual)

### CRD Path

Le Gateway API Controller peut installer différentes versions des CRDs:
- `config/crd/standard`: Gateway API version stable
- `config/crd/experimental`: Gateway API avec features expérimentales (v1)

Notre configuration utilise `experimental` pour avoir accès aux dernières fonctionnalités Gateway API v1.

## Utilisation

### Gateway Resource

Créer une Gateway pour exposer des services:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: nginx
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
      - name: my-tls-secret
```

### HTTPRoute Resource

Configurer le routage HTTP:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-route
  namespace: default
spec:
  parentRefs:
  - name: my-gateway
  hostnames:
  - "example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /app
    backendRefs:
    - name: my-service
      port: 80
```

### GatewayClass

Vérifier les GatewayClass disponibles:
```bash
kubectl get gatewayclass
```

## Vérification

### Vérifier le déploiement

```bash
# CRDs Gateway API installées
kubectl get crd | grep gateway

# GatewayClass disponibles
kubectl get gatewayclass

# Gateways
kubectl get gateway --all-namespaces

# HTTPRoutes
kubectl get httproute --all-namespaces
```

### Vérifier une Gateway

```bash
# Status de la Gateway
kubectl describe gateway my-gateway

# Listeners configurés
kubectl get gateway my-gateway -o jsonpath='{.spec.listeners}'

# Status des listeners
kubectl get gateway my-gateway -o jsonpath='{.status.listeners}'
```

## Troubleshooting

### CRDs pas installées

**Problème**: Gateway API CRDs non trouvées

**Solution**:
```bash
# Vérifier l'installation du controller
kubectl get pods -n gateway-system

# Vérifier les CRDs
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd gatewayclasses.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io

# Si manquantes, réinstaller l'application
kubectl delete app gateway-api-controller -n argo-cd
```

### Gateway pas Ready

**Problème**: Gateway reste en condition `Ready: False`

**Vérifications**:
```bash
# Status détaillé
kubectl describe gateway my-gateway

# Events
kubectl get events -n default --sort-by='.lastTimestamp'

# Vérifier le GatewayClass
kubectl get gatewayclass

# Logs du controller
kubectl logs -n gateway-system deployment/gateway-api-controller
```

## Docs

- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Gateway API Guides](https://gateway-api.sigs.k8s.io/guides/)
- [Gateway API Concepts](https://gateway-api.sigs.k8s.io/concepts/)
