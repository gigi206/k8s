# Envoy Gateway

Implémentation officielle d'EnvoyProxy pour Gateway API.

## Overview

**Envoy Gateway** est l'implémentation de référence du projet Envoy pour l'API Gateway de Kubernetes. Il fournit un contrôleur Gateway API et déploie automatiquement des proxies Envoy pour gérer le trafic ingress.

- **Documentation**: https://gateway.envoyproxy.io/
- **Repository**: https://github.com/envoyproxy/gateway
- **Helm Chart**: `oci://docker.io/envoyproxy/gateway-helm`
- **Version Envoy Gateway**: v1.6.0
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
│  - Watches Gateway API resources                            │
│  - Provisions Envoy Proxy instances                         │
│  - Configures Envoy via xDS API                             │
│  Namespace: envoy-gateway-system                            │
└────────────────────────┬────────────────────────────────────┘
                         │
                         v
┌─────────────────────────────────────────────────────────────┐
│                   Envoy Proxy Fleet                          │
│  - One deployment per Gateway resource                       │
│  - LoadBalancer service (MetalLB)                           │
│  - Handles HTTP/HTTPS/TCP traffic                           │
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

## Deployment

### Non installé par défaut

Envoy Gateway **N'EST PAS** déployé automatiquement avec le cluster. Il doit être activé manuellement.

### Installation manuelle

```bash
# Déployer l'ApplicationSet
kubectl apply -f deploy/argocd/apps/envoy-gateway/applicationset.yaml

# Vérifier le déploiement
kubectl get applicationset -n argo-cd envoy-gateway
kubectl get application -n argo-cd envoy-gateway

# Attendre que l'application soit synchronisée
kubectl wait --for=condition=Synced application/envoy-gateway -n argo-cd --timeout=5m
```

### Vérification du déploiement

```bash
# Vérifier les pods
kubectl get pods -n envoy-gateway-system

# Vérifier la GatewayClass
kubectl get gatewayclass envoy

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

## Testing

### 1. Déployer une Gateway de test

```bash
# Créer une Gateway avec listeners HTTP et HTTPS
kubectl apply -f deploy/argocd/apps/envoy-gateway/resources/gateway.yaml

# Vérifier la Gateway
kubectl get gateway -n default envoy-test-gateway
kubectl describe gateway -n default envoy-test-gateway

# Vérifier que le LoadBalancer a reçu une IP
kubectl get svc -n envoy-gateway-system
```

### 2. Déployer une HTTPRoute de test

```bash
# Créer une HTTPRoute vers le service kubernetes (API)
kubectl apply -f deploy/argocd/apps/envoy-gateway/resources/httproute.yaml

# Vérifier la HTTPRoute
kubectl get httproute -n default envoy-test-route
kubectl describe httproute -n default envoy-test-route
```

### 3. Tester le routage

```bash
# Récupérer l'IP du LoadBalancer
GATEWAY_IP=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-test-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "Gateway IP: $GATEWAY_IP"

# Tester la route HTTP
curl -H "Host: envoy-test.gigix" http://$GATEWAY_IP

# Tester la route HTTPS (si certificat configuré)
curl -k -H "Host: envoy-test.gigix" https://$GATEWAY_IP
```

### 4. Vérifier les métriques Prometheus

```bash
# Port-forward vers le service de métriques
kubectl port-forward -n envoy-gateway-system deployment/envoy-gateway 19001:19001

# Dans un autre terminal, récupérer les métriques
curl http://localhost:19001/metrics | grep envoy_gateway
```

### 5. Vérifier les alertes Prometheus

```bash
# Vérifier que les PrometheusRules sont chargées
kubectl get prometheusrules -n envoy-gateway-system

# Accéder à Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090

# Ouvrir http://localhost:9090/rules et chercher "envoy-gateway"
```

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

## Coexistence avec autres Gateways

Envoy Gateway peut coexister avec d'autres implémentations Gateway API :

| Gateway | GatewayClass | Namespace | Wave | Status |
|---------|--------------|-----------|------|--------|
| **Envoy Gateway** | `envoy` | envoy-gateway-system | 41 | Optionnel |
| Istio Gateway | `istio` | istio-system | 45 | Actif (dev) |
| NGINX Gateway Fabric | `nginx-gwf` | nginx-gateway | 41 | Désactivé |

Chaque Gateway utilise une GatewayClass distincte, permettant de router le trafic vers l'implémentation souhaitée.

## Troubleshooting

### Gateway not ready

```bash
# Vérifier les events
kubectl describe gateway -n default envoy-test-gateway

# Vérifier les logs du contrôleur
kubectl logs -n envoy-gateway-system deployment/envoy-gateway --tail=100

# Vérifier que la GatewayClass existe
kubectl get gatewayclass envoy -o yaml
```

### HTTPRoute not routing traffic

```bash
# Vérifier le status de la HTTPRoute
kubectl get httproute -n default envoy-test-route -o yaml

# Vérifier que la Gateway parent est correcte
kubectl describe httproute -n default envoy-test-route

# Vérifier les logs du proxy Envoy
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=envoy-test-gateway
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

### Metrics not available

```bash
# Vérifier que le port metrics est exposé
kubectl get svc -n envoy-gateway-system -o yaml | grep 19001

# Tester directement le pod
kubectl exec -n envoy-gateway-system deployment/envoy-gateway -- curl localhost:19001/metrics
```

## Migration from Istio/NGINX

Pour migrer du trafic depuis Istio ou NGINX Gateway Fabric :

1. **Déployer Envoy Gateway** (pas de downtime, coexistence)
2. **Créer une Gateway Envoy** avec la même configuration que la Gateway existante
3. **Migrer les HTTPRoutes** progressivement en changeant le `parentRef`
4. **Vérifier le trafic** sur la nouvelle Gateway
5. **Supprimer les anciennes routes** une fois la migration validée

## References

- **Official Docs**: https://gateway.envoyproxy.io/docs/
- **Installation Guide**: https://gateway.envoyproxy.io/docs/install/gateway-helm-api/
- **Gateway API Spec**: https://gateway-api.sigs.k8s.io/
- **GitHub**: https://github.com/envoyproxy/gateway
- **Releases**: https://github.com/envoyproxy/gateway/releases
- **Helm Chart**: https://github.com/envoyproxy/gateway/tree/main/charts/gateway-helm

## Sync Wave

**Wave 41** - Deploy after Gateway API CRDs (Wave 15), alongside other Gateway implementations.

Dependencies:
- MetalLB (Wave 10) - LoadBalancer provider
- Gateway API Controller (Wave 15) - CRDs
- Cert-Manager (Wave 20) - Optional, for TLS certificates
