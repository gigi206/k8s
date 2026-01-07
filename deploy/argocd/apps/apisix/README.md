# APISIX API Gateway

Apache APISIX is a dynamic, real-time, high-performance API Gateway.

## Overview

APISIX provides rich traffic management features like load balancing, dynamic upstream, canary release, circuit breaking, authentication, observability, and more.

## Architecture

- **APISIX Gateway**: Main API Gateway service (LoadBalancer)
- **Admin API**: Management API for APISIX (ClusterIP)
- **Embedded ETCD**: Configuration storage (StatefulSet with persistent volumes)

## Configuration

### Dev Environment

- **Namespace**: `apisix`
- **Chart Version**: 2.12.3
- **App Version**: 3.14.1
- **Service Type**: LoadBalancer
- **Replicas**: 1
- **ETCD**: Single replica with 2Gi storage
- **Auto-sync**: Enabled

### Production Environment

- **Namespace**: `apisix`
- **Replicas**: 3
- **ETCD**: 3 replicas with 10Gi storage
- **Auto-sync**: Disabled (manual sync required)
- **Resources**: Higher CPU/memory limits

## Deployment

APISIX is NOT deployed automatically during cluster installation. Deploy manually:

```bash
# Export KUBECONFIG
export KUBECONFIG=/path/to/vagrant/.kube/config-dev

# Apply ApplicationSet
kubectl apply -f deploy/argocd/apps/apisix/applicationset.yaml

# Monitor deployment
kubectl get application -n argo-cd apisix -w

# Check APISIX pods
kubectl get pods -n apisix
```

## Access

### Gateway Service

The main APISIX gateway is exposed via LoadBalancer:

```bash
# Get LoadBalancer IP
kubectl get svc -n apisix apisix-gateway

# Test access
curl http://<LOADBALANCER-IP>
```

### APISIX Dashboard

The APISIX Dashboard provides a web-based UI for managing routes, upstreams, and plugins.

**Access**: https://apisix.k8s.local

**Authentication**: Keycloak OIDC via `openid-connect` plugin

| Parameter | Dev | Prod |
|-----------|-----|------|
| Chart Version | 0.8.3 | 0.8.3 |
| Replicas | 1 | 2 |
| Authentication | OIDC via Keycloak | OIDC via Keycloak |

> **Note**: The `apisix-dashboard` chart is marked as DEPRECATED but remains functional.

#### Authentication Architecture

```
                                    ┌─────────────────────┐
                                    │   Keycloak OIDC     │
                                    └──────────┬──────────┘
                                               │
User Request ──► APISIX Gateway ──► openid-connect plugin
                                               │
                      ┌────────────────────────┼────────────────────────┐
                      │                        │                        │
                      ▼                        ▼                        ▼
              Not authenticated        Token valid              Token invalid
                      │                        │                        │
                      ▼                        ▼                        ▼
              Redirect to Keycloak    Forward to Dashboard      401 Unauthorized
```

The OIDC authentication happens **at the APISIX Gateway level** (via `openid-connect` plugin on the ApisixRoute), **before** requests reach the dashboard. This means:
- The dashboard never receives unauthenticated requests
- The dashboard's internal authentication is never used
- Local credentials are purely for chart compatibility

#### Secrets Management (SOPS)

All dashboard credentials are encrypted with SOPS and injected via a PostSync Job:

```
secrets/dev/secret.yaml (SOPS encrypted)
├── apisix-dashboard-oidc-client-secret  → namespace: keycloak (for Keycloak client)
│   ├── client-secret
│   └── session-secret
└── apisix-dashboard-auth                → namespace: apisix (for dashboard config)
    ├── jwt-secret
    └── admin-password
```

**How it works**:
1. KSOPS decrypts `secrets/dev/secret.yaml` and creates K8s Secrets
2. PostSync Job `apisix-dashboard-configmap-patch` reads the Secret
3. Job patches the dashboard ConfigMap with the decrypted credentials
4. Dashboard deployment is restarted to pick up new config

This approach keeps credentials encrypted in Git while satisfying the chart's requirement for authentication config.

#### Troubleshooting Dashboard

```bash
# Check dashboard pods
kubectl get pods -n apisix -l app.kubernetes.io/name=apisix-dashboard

# Check dashboard logs
kubectl logs -n apisix -l app.kubernetes.io/name=apisix-dashboard

# Check ConfigMap patch Job
kubectl get jobs -n apisix -l job-name=apisix-dashboard-configmap-patch
kubectl logs -n apisix -l job-name=apisix-dashboard-configmap-patch

# Verify secrets exist
kubectl get secret -n apisix apisix-dashboard-auth
kubectl get secret -n keycloak apisix-dashboard-oidc-client-secret

# Verify OIDC configuration
curl -sk https://keycloak.k8s.local/realms/k8s/.well-known/openid-configuration | jq .

# Check Keycloak client exists (requires admin access)
# The client "apisix-dashboard" should be created by the PostSync Job
```

### Admin API

The Admin API is available as ClusterIP service. Use port-forward for access:

```bash
# Port forward to Admin API
kubectl port-forward -n apisix svc/apisix-admin 9180:9180

# Access Admin API (requires auth token)
curl -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://localhost:9180/apisix/admin/routes
```

**Default Credentials** (change in production):
- Admin key: `edd1c9f034335f136f87ad84b625c8f1`
- Viewer key: `4054f7cf07e344346cd3f287985e76a2`

## Testing

### Create a Test Route

```bash
# Create a simple route that proxies to httpbin.org
curl http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '
{
  "uri": "/get",
  "upstream": {
    "type": "roundrobin",
    "nodes": {
      "httpbin.org:80": 1
    }
  }
}'

# Test the route
GATEWAY_IP=$(kubectl get svc -n apisix apisix-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$GATEWAY_IP/get
```

## OAuth2 Authentication

APISIX provides OAuth2 authentication for protected applications. The implementation differs between HTTPRoute and ApisixRoute.

### Summary

| Route Type | OAuth2 Implementation |
|------------|----------------------|
| **HTTPRoute** | Label + CronJob + Global Rule |
| **ApisixRoute** | forward-auth + serverless-post-function plugins |

### ApisixRoute with forward-auth Plugin

For ApisixRoute, use the `forward-auth` plugin to validate tokens with oauth2-proxy, and `serverless-post-function` to convert 401 responses to 302 redirects:

```yaml
---
# Cross-namespace upstream to oauth2-proxy (required in each namespace)
apiVersion: apisix.apache.org/v2
kind: ApisixUpstream
metadata:
  name: oauth2-proxy
  namespace: my-namespace
spec:
  externalNodes:
    - type: Domain
      name: oauth2-proxy.oauth2-proxy.svc.cluster.local
      port: 4180
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: my-protected-app
  namespace: my-namespace
spec:
  ingressClassName: apisix
  http:
    # Route /oauth2/* to OAuth2 Proxy for authentication flow
    - name: oauth2
      match:
        hosts:
          - my-app.k8s.lan
        paths:
          - /oauth2/*
      upstreams:
        - name: oauth2-proxy
      plugins:
        - name: proxy-rewrite
          enable: true
          config:
            regex_uri: ["^/oauth2/(.*)", "/$1"]
    # Route all other traffic (protected by OAuth2)
    - name: main
      match:
        hosts:
          - my-app.k8s.lan
        paths:
          - /*
      backends:
        - serviceName: my-app-service
          servicePort: 8080
      plugins:
        # Validate token with oauth2-proxy
        - name: forward-auth
          enable: true
          config:
            uri: http://oauth2-proxy.oauth2-proxy.svc:4180/oauth2/auth
            request_headers: ["Authorization", "Cookie"]
            upstream_headers: ["X-Auth-Request-User", "X-Auth-Request-Email"]
            client_headers: ["Set-Cookie"]
        # Convert 401 to 302 redirect (forward-auth doesn't handle redirects)
        - name: serverless-post-function
          enable: true
          config:
            phase: header_filter
            functions:
              - "return function() if ngx.status == 401 then ngx.status = 302; ngx.header['Location'] = '/oauth2/start?rd=' .. ngx.escape_uri(ngx.var.scheme .. '://' .. ngx.var.host .. ngx.var.request_uri) end end"
```

**Key Points**:
- Create `ApisixUpstream` for cross-namespace access to oauth2-proxy
- Route `/oauth2/*` to oauth2-proxy with path rewrite
- Use `forward-auth` plugin to validate session cookie
- Use `serverless-post-function` to redirect unauthenticated users

### HTTPRoute with Global Rule (Legacy)

For HTTPRoute, OAuth2 protection uses a Global Rule that discovers HTTPRoutes dynamically.

#### How It Works

1. **Label HTTPRoutes**: Add `oauth2-protected: "true"` label to HTTPRoutes that need authentication
2. **CronJob Discovery**: A CronJob runs every 2 minutes to discover labeled HTTPRoutes
3. **Global Rule**: APISIX Global Rule redirects unauthenticated requests to OAuth2 Proxy

#### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  HTTPRoute (monitoring/prometheus)                              │
│  labels:                                                        │
│    oauth2-protected: "true"                                     │
│  hostnames:                                                     │
│    - prometheus.k8s.lan                                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  CronJob: apisix-oauth2-plugin-applicator (every 2 min)         │
│                                                                 │
│  kubectl get httproutes -A -l oauth2-protected=true             │
│  → Discovers: prometheus.k8s.lan, alertmanager.k8s.lan, ...     │
│  → Updates APISIX Global Rule                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  APISIX Global Rule: oauth2-forward-auth                        │
│                                                                 │
│  1. Check if host is in protected list                          │
│  2. Skip /oauth2/* paths (OAuth2 Proxy callback)                │
│  3. Check for _oauth2_proxy session cookie                      │
│  4. Redirect to /oauth2/start if no cookie                      │
└─────────────────────────────────────────────────────────────────┘
```

#### Protecting a New Application (HTTPRoute)

To add OAuth2 protection to an HTTPRoute application:

1. **Add the label to HTTPRoute**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-namespace
  labels:
    oauth2-protected: "true"  # Add this label
spec:
  hostnames:
    - "my-app.k8s.lan"
  rules:
    # Route /oauth2/* to OAuth2 Proxy (required for login flow)
    - matches:
        - path:
            type: PathPrefix
            value: /oauth2/
      backendRefs:
        - name: oauth2-proxy
          namespace: oauth2-proxy
          port: 4180
    # Route all other traffic to your app
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-service
          port: 8080
```

2. **Wait for CronJob** (max 2 minutes) or trigger manually:

```bash
kubectl create job -n apisix oauth2-manual --from=cronjob/apisix-oauth2-plugin-applicator
```

3. **Verify the Global Rule**:

```bash
curl -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://localhost:9180/apisix/admin/global_rules/oauth2-forward-auth
```

#### Removing OAuth2 Protection (HTTPRoute)

Remove the label from the HTTPRoute:

```bash
kubectl label httproute -n my-namespace my-app oauth2-protected-
```

The CronJob will automatically update the Global Rule on its next run.

### Currently Protected Applications

| Application | Route Type | Namespace | Hostname |
|-------------|------------|-----------|----------|
| Prometheus | ApisixRoute | monitoring | prometheus.k8s.lan |
| Alertmanager | ApisixRoute | monitoring | alertmanager.k8s.lan |
| Hubble UI | ApisixRoute | kube-system | hubble.k8s.lan |
| Kiali | ApisixRoute | istio-system | kiali.k8s.lan |
| Jaeger | ApisixRoute | observability | jaeger.k8s.lan |
| Longhorn | ApisixRoute | longhorn-system | longhorn.k8s.lan |

**Note**: Ceph Dashboard and NeuVector use their own SSO integration (SAML2 with Keycloak) instead of OAuth2 Proxy.

### Troubleshooting OAuth2

```bash
# Check CronJob status
kubectl get cronjob -n apisix apisix-oauth2-plugin-applicator

# View latest job logs
kubectl logs -n apisix -l app=oauth2-plugin-applicator --tail=50

# List protected HTTPRoutes
kubectl get httproutes -A -l oauth2-protected=true

# Check Global Rule
curl -s -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://localhost:9180/apisix/admin/global_rules/oauth2-forward-auth | jq .

# Test redirect (should return 302)
curl -s -k -o /dev/null -w "%{http_code}\n" https://prometheus.k8s.lan/
```

## HTTPS Backends

When routing to backend services that use HTTPS (e.g., Ceph Dashboard, NeuVector), APISIX needs to know the backend protocol. The configuration differs between ApisixRoute (native CRDs) and HTTPRoute (Gateway API).

### Summary

| Route Type | HTTPS Backend Solution | Custom Service Required |
|------------|------------------------|------------------------|
| **ApisixRoute** | `ApisixUpstream` with `scheme: https` | No |
| **HTTPRoute** | `appProtocol: https` on Service | Yes (if upstream doesn't set it) |

### ApisixRoute with ApisixUpstream (Recommended)

For ApisixRoute, use an `ApisixUpstream` resource with `scheme: https`. The upstream name must match the Kubernetes Service name:

```yaml
---
# ApisixUpstream must be in the same file to ensure correct ordering
apiVersion: apisix.apache.org/v2
kind: ApisixUpstream
metadata:
  name: my-https-service  # Must match Service name
  namespace: my-namespace
spec:
  scheme: https
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: my-route
  namespace: my-namespace
spec:
  ingressClassName: apisix
  http:
    - name: my-route
      match:
        hosts:
          - my-app.k8s.lan
        paths:
          - /*
      backends:
        - serviceName: my-https-service  # Original Service (no appProtocol needed)
          servicePort: 8443
```

**Important**: Place both resources in the same YAML file to ensure the `ApisixUpstream` is created before the `ApisixRoute`. This avoids timing issues during ArgoCD sync.

### HTTPRoute with appProtocol

For HTTPRoute (Gateway API), APISIX auto-detects the backend protocol from the Service's `appProtocol` field:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-https-service
  namespace: my-namespace
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - name: https
      port: 8443
      targetPort: 8443
      protocol: TCP
      appProtocol: https  # Required for HTTPRoute HTTPS backends
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-route
  namespace: my-namespace
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: default-gateway
      namespace: apisix
  hostnames:
    - my-app.k8s.lan
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-https-service
          port: 8443
```

**Note**: If the upstream Helm chart doesn't set `appProtocol` on its Service, you need to create a custom Service with the same selector that adds `appProtocol: https`.

### BackendTrafficPolicy (Not Recommended)

APISIX provides a `BackendTrafficPolicy` CRD with `scheme: https`, but testing shows it doesn't work reliably with internal Services. Use `appProtocol` instead for HTTPRoute.

### Current HTTPS Backend Applications

| Application | Route Type | Solution |
|-------------|------------|----------|
| Ceph Dashboard | ApisixRoute | ApisixUpstream (scheme: https) |
| NeuVector Manager | ApisixRoute | ApisixUpstream (scheme: https) |

## Monitoring

### Prometheus Metrics

APISIX exports Prometheus metrics automatically via ServiceMonitor.

```bash
# Check ServiceMonitor
kubectl get servicemonitor -n apisix

# Access metrics endpoint
kubectl port-forward -n apisix svc/apisix-gateway 9091:9091
curl http://localhost:9091/apisix/prometheus/metrics
```

### Prometheus Alerts

The following alert categories are configured:

**Critical Alerts**:
- `ApisixDown`: No available replicas
- `ApisixPodCrashLooping`: Pod restart loops
- `ApisixEtcdDown`: ETCD unavailable

**High Severity Alerts**:
- `ApisixHighHTTPErrorRate`: >5% HTTP 5xx errors
- `ApisixHighLatency`: p99 latency >5s
- `ApisixEtcdReplicasMismatch`: ETCD replicas not ready

**Warning Alerts**:
- `ApisixReplicasMismatch`: Replica count mismatch
- `ApisixHighMemoryUsage`: >90% memory usage
- `ApisixHighCPUUsage`: >90% CPU usage
- `ApisixEtcdPersistentVolumeSpaceLow`: <15% disk space

**Medium Alerts**:
- `ApisixConfigSyncErrors`: ETCD sync errors
- `ApisixConnectionsHigh`: >5000 active connections

### Grafana Dashboards

View APISIX metrics in Grafana:

```bash
# Access Grafana
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80

# Default credentials: admin/prom-operator
# Import APISIX dashboard: https://grafana.com/grafana/dashboards/11719
```

## Troubleshooting

### APISIX Not Starting

```bash
# Check pod logs
kubectl logs -n apisix -l app.kubernetes.io/name=apisix

# Check ETCD connectivity
kubectl logs -n apisix -l app.kubernetes.io/name=apisix | grep -i etcd
```

### ETCD Issues

```bash
# Check ETCD pods
kubectl get pods -n apisix -l app.kubernetes.io/name=etcd

# Check ETCD logs
kubectl logs -n apisix -l app.kubernetes.io/name=etcd

# Check persistent volumes
kubectl get pvc -n apisix
```

### Routes Not Working

```bash
# List all routes
curl -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  http://localhost:9180/apisix/admin/routes

# Check APISIX logs for errors
kubectl logs -n apisix -l app.kubernetes.io/name=apisix --tail=100
```

## References

- [Apache APISIX Documentation](https://apisix.apache.org/docs/apisix/getting-started/)
- [APISIX Helm Chart](https://github.com/apache/apisix-helm-chart)
- [APISIX Admin API](https://apisix.apache.org/docs/apisix/admin-api/)
- [APISIX Plugins](https://apisix.apache.org/docs/apisix/plugins/overview/)
