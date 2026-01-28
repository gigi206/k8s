# Istio Gateway

Istio Gateway provides ingress capabilities for the service mesh using Gateway API.

## Overview

- **Wave**: 45 (after Istio control plane at )
- **Namespace**: `istio-system`
- **Provider**: Part of Istio service mesh
- **GatewayClass**: `istio`

## Features

- Gateway API native implementation
- TLS termination with cert-manager certificates
- HTTPRoute support for traffic routing
- Integration with Istio's mTLS mesh
- Automatic HTTPS redirect

## Components Deployed

### Gateway Resource

Creates the main `Gateway` resource using the `istio` GatewayClass:
- HTTP listener on port 80 (redirects to HTTPS)
- HTTPS listener on port 443 with wildcard certificate

### Wildcard Certificate

Uses cert-manager to provision a wildcard certificate (`*.domain`) for TLS termination.

### Wait-for-Webhook Job

Pre-sync job that waits for Istio's webhook to be ready before deploying Gateway resources.

## Configuration

### Dev (config/dev.yaml)

```yaml
istio:
  namespace: istio-system
  version: "1.28.0"  # Must match istio control plane version

  ingressGateway:
    kind: "DaemonSet"  # DaemonSet (1 per node) or Deployment
    replicas: 1        # Only used if kind=Deployment
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
        memory: "1Gi"
```

### Prod (config/prod.yaml)

```yaml
istio:
  ingressGateway:
    kind: "Deployment"
    replicas: 3  # HA
    resources:
      requests:
        cpu: "200m"
        memory: "512Mi"
      limits:
        cpu: "2000m"
        memory: "2Gi"
```

## Usage

### Creating an HTTPRoute

Route traffic to your service via the Istio Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  parentRefs:
   - name: istio-gateway
      namespace: istio-system
  hostnames:
   - "myapp.k8s.lan"
  rules:
   - matches:
       - path:
            type: PathPrefix
            value: /
      backendRefs:
       - name: my-service
          port: 8080
```

### HTTPS with Automatic Certificate

The Gateway uses a wildcard certificate for `*.k8s.lan`. Your HTTPRoute automatically gets HTTPS.

### Header-Based Routing

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: canary-route
spec:
  parentRefs:
   - name: istio-gateway
      namespace: istio-system
  hostnames:
   - "myapp.k8s.lan"
  rules:
   - matches:
       - headers:
           - name: "X-Canary"
              value: "true"
      backendRefs:
       - name: my-service-canary
          port: 8080
   - backendRefs:
       - name: my-service
          port: 8080
```

## Verification

```bash
# Vérifier le Gateway
kubectl get gateway -n istio-system istio-gateway
kubectl describe gateway -n istio-system istio-gateway

# Vérifier le certificat wildcard
kubectl get certificate -n istio-system
kubectl describe certificate -n istio-system wildcard-tls

# Vérifier le service LoadBalancer
kubectl get svc -n istio-system istio-gateway-istio

# Lister les HTTPRoutes
kubectl get httproute -A

# Tester l'accès
curl -k https://grafana.k8s.lan
```

## Troubleshooting

### Gateway not ready

```bash
# Vérifier les pods du gateway
kubectl get pods -n istio-system -l istio=gateway

# Logs du gateway
kubectl logs -n istio-system -l istio=gateway

# Events
kubectl describe gateway -n istio-system istio-gateway
```

### HTTPRoute not working

```bash
# Vérifier le status de la route
kubectl describe httproute -n my-namespace my-route

# Vérifier que le service backend existe
kubectl get svc -n my-namespace my-service

# Vérifier les endpoints
kubectl get endpoints -n my-namespace my-service
```

### Certificate issues

```bash
# Status du certificat
kubectl describe certificate -n istio-system wildcard-tls

# Vérifier le secret TLS
kubectl get secret -n istio-system wildcard-tls

# Logs cert-manager
kubectl logs -n cert-manager -l app=cert-manager
```

### Service unavailable (503)

```bash
# Vérifier que le service est dans le mesh
kubectl get namespace my-namespace --show-labels | grep istio

# Vérifier les pods backend
kubectl get pods -n my-namespace -l app=my-app

# Logs du gateway pour cette route
kubectl logs -n istio-system -l istio=gateway | grep my-app
```

## Dependencies

- **istio**: Requires Istio control plane
- **cert-manager**: Requires cert-manager for TLS certificates
- **gateway-api-controller**: Requires Gateway API CRDs

## References

- [Istio Gateway API](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [HTTPRoute Reference](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)
