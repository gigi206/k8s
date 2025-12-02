# External Secrets Operator

## Overview

External Secrets Operator (ESO) synchronizes secrets from external secret management systems into Kubernetes Secrets. In this cluster, it is used to synchronize OIDC client secrets from the `keycloak` namespace to application namespaces.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ keycloak namespace (source of truth)                                │
│                                                                     │
│  argocd-oidc-client-secret ◄─────────────────────────────────────┐ │
│  grafana-oidc-client-secret ◄──────────────────────────────────┐ │ │
└───────────────────────────────────────────────────────────────│─│─┘
                                                                │ │
┌──────────────────────────────────────────────────────────────│─│─┐
│ ClusterSecretStore "keycloak-oidc-secrets"                   │ │ │
│ (reads secrets from keycloak namespace)                      │ │ │
└──────────────────────────────────────────────────────────────│─│─┘
                                                                │ │
    ┌───────────────────────────────────────────────────────────┘ │
    │                                                             │
    ▼                                                             ▼
┌─────────────────────────────┐  ┌─────────────────────────────────┐
│ argo-cd namespace           │  │ monitoring namespace            │
│                             │  │                                 │
│ ExternalSecret              │  │ ExternalSecret                  │
│ → argocd-secret             │  │ → grafana-oidc-credentials      │
└─────────────────────────────┘  └─────────────────────────────────┘
```

## Components

### ClusterSecretStore

Defined in `apps/keycloak/resources/cluster-secret-store.yaml`, the ClusterSecretStore allows ExternalSecrets from any namespace to read secrets from the `keycloak` namespace.

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: keycloak-oidc-secrets
spec:
  provider:
    kubernetes:
      remoteNamespace: keycloak
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
          namespace: kube-system
      auth:
        serviceAccount:
          name: external-secrets
          namespace: external-secrets
```

### ExternalSecrets

Each application that needs OIDC secrets defines an ExternalSecret:

- **ArgoCD**: `apps/argocd/resources/external-secret.yaml`
  - Source: `keycloak/argocd-oidc-client-secret`
  - Target: `argo-cd/argocd-secret`

- **Grafana**: `apps/prometheus-stack/resources/external-secret.yaml`
  - Source: `keycloak/grafana-oidc-client-secret`
  - Target: `monitoring/grafana-oidc-credentials`

## Sync Wave

External Secrets Operator is deployed at **Wave 25**, ensuring it's available before applications that depend on it:

- Wave 25: External Secrets Operator
- Wave 50: ArgoCD (uses ExternalSecret)
- Wave 75: Prometheus-Stack (uses ExternalSecret for Grafana)
- Wave 80: Keycloak (provides source secrets)

## Adding a New Application

To add OIDC support for a new application:

1. **Create source secret in keycloak namespace**:
   ```yaml
   # apps/keycloak/secrets/dev/secret-myapp-client.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: myapp-oidc-client-secret
     namespace: keycloak
   stringData:
     client-secret: "<generated-secret>"
   ```

2. **Add to ksops-generator.yaml**:
   ```yaml
   files:
     - ./secret-myapp-client.yaml
   ```

3. **Create KeycloakRealmImport** in your app's resources:
   ```yaml
   # apps/myapp/resources/keycloak-client.yaml
   apiVersion: k8s.keycloak.org/v2alpha1
   kind: KeycloakRealmImport
   metadata:
     name: myapp-oidc-client
     namespace: keycloak
   spec:
     keycloakCRName: keycloak
     realm:
       realm: gigix
       clients:
         - clientId: myapp
           secret: "$(env:MYAPP_CLIENT_SECRET)"
           # ... client config
     placeholders:
       MYAPP_CLIENT_SECRET:
         secret:
           name: myapp-oidc-client-secret
           key: client-secret
   ```

4. **Create ExternalSecret** in your app's resources:
   ```yaml
   # apps/myapp/resources/external-secret.yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: myapp-oidc-external
     namespace: myapp
   spec:
     refreshInterval: 1h
     secretStoreRef:
       kind: ClusterSecretStore
       name: keycloak-oidc-secrets
     target:
       name: myapp-oidc-credentials
     data:
       - secretKey: client-secret
         remoteRef:
           key: myapp-oidc-client-secret
           property: client-secret
   ```

5. **Update your ApplicationSet** to include the resources source.

## Troubleshooting

### Check ExternalSecret status
```bash
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>
```

### Check ClusterSecretStore status
```bash
kubectl get clustersecretstore
kubectl describe clustersecretstore keycloak-oidc-secrets
```

### Verify synced secret
```bash
kubectl get secret <target-secret> -n <namespace> -o yaml
```

### Force refresh
```bash
kubectl annotate externalsecret <name> -n <namespace> \
  force-sync=$(date +%s) --overwrite
```

## References

- [External Secrets Operator Documentation](https://external-secrets.io/)
- [Kubernetes Provider](https://external-secrets.io/latest/provider/kubernetes/)
