# Istio Gateway

Istio Gateway provides ingress capabilities for the service mesh using Gateway API.

## Overview

- **Wave**: 45 (after Istio control plane at Wave 40)
- **Namespace**: `istio-system`
- **Provider**: Part of Istio service mesh

## Features

- Gateway API native implementation
- TLS termination with cert-manager certificates
- HTTPRoute support for traffic routing
- Integration with Istio's mTLS mesh

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

```yaml
# config/dev.yaml
istioGateway:
  tls:
    secretName: wildcard-k8s-local-tls
```

## Dependencies

- **istio**: Requires Istio control plane (Wave 40)
- **certManager**: Requires cert-manager for TLS certificates
- **gatewayAPI**: Requires Gateway API CRDs

## References

- [Istio Gateway API](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
