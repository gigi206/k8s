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
