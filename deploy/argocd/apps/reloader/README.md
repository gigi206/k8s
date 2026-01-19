# Reloader - ConfigMap & Secret Change Watcher

Stakater Reloader watches ConfigMaps and Secrets and performs rolling upgrades on Pods when their configuration changes.

## Overview

- **Wave**: 25
- **Namespace**: `reloader`
- **Helm Chart**: [stakater/reloader](https://github.com/stakater/Reloader)

## Usage

Add annotations to your Deployment, StatefulSet, or DaemonSet to enable automatic reloading:

### Watch specific Secret

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "my-secret"
```

### Watch specific ConfigMap

```yaml
metadata:
  annotations:
    configmap.reloader.stakater.com/reload: "my-configmap"
```

### Watch multiple resources

```yaml
metadata:
  annotations:
    secret.reloader.stakater.com/reload: "secret1,secret2"
    configmap.reloader.stakater.com/reload: "config1,config2"
```

### Auto-reload all referenced ConfigMaps/Secrets

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

## Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  annotations:
    secret.reloader.stakater.com/reload: "my-app-secrets"
    configmap.reloader.stakater.com/reload: "my-app-config"
spec:
  template:
    spec:
      containers:
        - name: my-app
          envFrom:
            - secretRef:
                name: my-app-secrets
            - configMapRef:
                name: my-app-config
```

When `my-app-secrets` or `my-app-config` changes, Reloader will trigger a rolling restart of the deployment.

## Configuration

```yaml
# config/dev.yaml
reloader:
  version: "2.2.7"
  replicas: 1
  resources:
    requests:
      cpu: "10m"
      memory: "32Mi"
```

## Monitoring

When monitoring is enabled, Reloader exposes Prometheus metrics:

- `reloader_reload_executed_total` - Total number of reloads executed
- `reloader_reload_failed_total` - Total number of failed reloads

### Alerts

| Alert | Severity | Description |
|-------|----------|-------------|
| ReloaderDown | warning | Reloader unavailable for 5m |
| ReloaderHighRestartRate | warning | More than 50 reloads in 5m |

## References

- [Reloader Documentation](https://github.com/stakater/Reloader)
- [Helm Chart](https://artifacthub.io/packages/helm/stakater/reloader)
