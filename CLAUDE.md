# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitOps infrastructure project that manages Kubernetes applications using ArgoCD with ApplicationSet pattern. The infrastructure supports multiple environments (dev/prod) with centralized configuration, Go templating, and per-application overrides.

## Prerequisites

- **mise**: For managing tool versions (yq, age, sops)
- **yq**: For parsing YAML configuration
- **kubectl**: For cluster interaction
- **helm**: For chart management
- **kustomize**: For manifest customization
- **argocd**: For ArgoCD interaction
- **yamllint**: For YAML style checking
- **vagrant**: For local cluster creation (dev environment)

## Key Architecture Concepts

### ApplicationSet-Based Application Management

- **One ApplicationSet per application** in `deploy/argocd/apps/<app-name>/applicationset.yaml`
- **Native Go templating** with conditional logic (`{{ if .features.monitoring.enabled }}`)
- **Per-application configuration** in `deploy/argocd/apps/<app-name>/config/{env}.yaml`
- **Git Merge Generator** combines global + app-specific config

### Configuration Hierarchy

1. **Global Config**: `deploy/argocd/config/config.yaml` (shared defaults, feature flags)
2. **App-Specific Config**: `deploy/argocd/apps/<app-name>/config/dev.yaml` or `prod.yaml`
3. **ApplicationSet**: `deploy/argocd/apps/<app-name>/applicationset.yaml`
4. **Resources**: `deploy/argocd/apps/<app-name>/resources/` (K8s manifests, values files)

### Version Management

Each application manages its own Helm chart version in config files:

```yaml
# apps/metallb/config/dev.yaml
metallb:
  version: "0.15.3"  # Helm chart version - Renovate updates this
```

**ApplicationSet reference**: `{{ .metallb.version }}`

### Directory Structure

```
deploy/argocd/
├── config/config.yaml              # Global configuration
├── .sops.yaml                      # SOPS encryption config
├── deploy-applicationsets.sh       # Deployment script
└── apps/<app-name>/
    ├── applicationset.yaml         # ApplicationSet definition
    ├── config/
    │   ├── dev.yaml               # Dev config + chart version
    │   └── prod.yaml              # Prod config
    ├── resources/                  # Raw YAML manifests (no transformations)
    ├── kustomize/                  # Kustomize overlays (with transformations)
    │   ├── monitoring/            # PrometheusRules, ServiceMonitors, dashboards
    │   ├── httproute/             # HTTPRoute (conditional: gatewayAPI.httpRoute.enabled)
    │   ├── oauth2-authz/          # AuthorizationPolicy (conditional: oauth2Proxy.enabled)
    │   └── custom-resources/      # App-specific CRs (keycloak)
    └── secrets/                    # SOPS-encrypted secrets
        ├── dev/
        └── prod/
```

### resources/ vs kustomize/ Directory Convention

**Criterion**: Does the directory use Kustomize transformations?

| Directory | Usage | Transformations |
|-----------|-------|-----------------|
| `resources/` | Raw YAML files deployed as-is | None - just `resources:` list |
| `kustomize/` | Overlays requiring processing | `patches`, `commonLabels`, `commonAnnotations`, `configMapGenerator`, etc. |

**Examples**:
- `resources/cilium-egress-policy.yaml` → Raw CiliumNetworkPolicy, no transformation needed
- `kustomize/monitoring/` → Uses `commonLabels: release: prometheus-stack` for Prometheus discovery
- `kustomize/httproute/` → Uses `patches` to inject `{{ .common.domain }}` dynamically

**In ApplicationSets**, conditional resources from `resources/` use `directory.include`:
```yaml
{{- if .features.cilium.egressPolicy.enabled }}
- path: deploy/argocd/apps/my-app/resources
  directory:
    include: "cilium-egress-policy.yaml"
{{- end }}
```

### Sync Wave Strategy

Applications are deployed in order using ArgoCD sync waves (lower = earlier). The wave number is defined in each ApplicationSet's `argocd.argoproj.io/sync-wave` annotation. See the Feature Flags table below for each application's wave.

### Feature Flags

Feature flags in `config/config.yaml` control which ApplicationSets are deployed:

| Feature Flag | ApplicationSet | Wave |
|-------------|----------------|------|
| `metallb.enabled` | metallb | 10 |
| `kubeVip.enabled` | kube-vip | 15 |
| `gatewayAPI.enabled` | gateway-api-controller | 15 |
| `certManager.enabled` | cert-manager | 20 |
| `externalSecrets.enabled` | external-secrets | 25 |
| `serviceMesh.enabled` + `provider=istio` | istio | 40 |
| `ingress.enabled` + `class=nginx` | ingress-nginx | 40 |
| `ingress.enabled` + `class=traefik` | traefik | 40 |
| `gatewayAPI.controller.provider=envoy-gateway` | envoy-gateway | 41 |
| `gatewayAPI.controller.provider=nginx-gateway-fabric` | nginx-gateway-fabric | 41 |
| `gatewayAPI.controller.provider=apisix` | apisix | 42 |
| `externalDns.enabled` | external-dns | 45 |
| `gatewayAPI.controller.provider=istio` | istio-gateway | 45 |
| *(always)* | argocd | 50 |
| `storage.csiSnapshotter` | csi-external-snapshotter | 55 |
| `storage.enabled` + `provider=longhorn` | longhorn | 60 |
| `storage.enabled` + `provider=rook` | rook | 60 |
| `databaseOperator.enabled` + `provider=cnpg` | cnpg-operator | 65 |
| `logging.enabled` + `logging.loki.enabled` | loki | 73 |
| `logging.enabled` + `logging.loki.collector=alloy` | alloy | 74 |
| `monitoring.enabled` | prometheus-stack | 75 |
| `cilium.monitoring.enabled` | cilium | 76 |
| `tracing.enabled` + `provider=tempo` | tempo | 77 |
| `tracing.enabled` + `provider=jaeger` | jaeger | 77 |
| `sso.enabled` + `provider=keycloak` | keycloak | 80 |
| `oauth2Proxy.enabled` | oauth2-proxy | 81 |
| `neuvector.enabled` | neuvector | 82 |

**Automatic Dependency Resolution**: The script enables dependencies automatically (e.g., `sso.provider=keycloak` enables `databaseOperator`, `externalSecrets`, `certManager`).

## Common Development Commands

### Full Environment Setup

```bash
make dev-full                    # Create Vagrant cluster + install everything
make vagrant-dev-up              # Create cluster only
make argocd-install-dev          # Install ArgoCD + deploy ApplicationSets
```

### Deploy/Update Applications

```bash
# Edit config, commit, push - ArgoCD auto-syncs (dev env)
vim deploy/argocd/apps/prometheus-stack/config/dev.yaml
git add . && git commit -m "Update config" && git push
```

### Monitoring Deployment

```bash
kubectl get applications -n argo-cd
kubectl get applicationsets -n argo-cd

# Force sync
kubectl -n argo-cd patch application <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Cluster Management

```bash
make vagrant-dev-status          # Check cluster status
make vagrant-dev-ssh             # SSH to master node
make vagrant-dev-destroy         # Delete cluster
```

## Working with Configuration

### Modifying an Application

1. Edit `deploy/argocd/apps/<app-name>/config/dev.yaml`
2. Commit and push to Git
3. ArgoCD auto-syncs (dev) or manually sync (prod)

### Adding a New Application

1. Create directory: `mkdir -p deploy/argocd/apps/my-app/{config,resources}`
2. Copy ApplicationSet from existing app as template
3. Create config files (`config/dev.yaml`, `config/prod.yaml`)
4. Add to `deploy-applicationsets.sh` if needed
5. **Add Prometheus alerts** (see Prometheus section)
6. **Add Renovate custom manager** in `renovate.json` (see Renovate section below)

## Renovate Configuration

When adding a new application:
1. Use `helm search repo <chart>` to get the latest version
2. Add a custom manager entry in `renovate.json` (see existing entries as reference)

## Go Template Variable Limitations

**CRITICAL**: Go templates (`{{ .variable }}`) **ONLY work in ApplicationSet definitions**, NOT in manifest files.

**Where Go templates work**:
- ApplicationSet `template` and `templatePatch` sections
- Helm `parameters` (as strings passed to Helm)

**Where Go templates DON'T work**:
- YAML manifests in `resources/` or `kustomize/*/` directories
- Helm values files
- Raw Kubernetes manifests

**Solution**: Use Kustomize replacements, Helm templating, or hardcoded values in manifests.

## Secrets Management (SOPS/KSOPS)

Secrets are encrypted in Git using SOPS with AGE encryption. ArgoCD decrypts at deploy time via KSOPS.

**Key Files**:
- `sops/age-dev.key`, `sops/age-prod.key` - AGE private keys
- `deploy/argocd/.sops.yaml` - SOPS config with public keys

**Structure**:
```
apps/<app-name>/secrets/
├── dev/
│   ├── kustomization.yaml
│   ├── ksops-generator.yaml
│   └── secret.yaml          # Encrypted
└── prod/
    └── ...
```

**Commands**:
```bash
cd deploy/argocd
sops encrypt --in-place apps/<app>/secrets/dev/secret.yaml  # Encrypt
sops apps/<app>/secrets/dev/secret.yaml                      # Edit in place
sops decrypt apps/<app>/secrets/dev/secret.yaml              # Decrypt (view)
```

> See `apps/prometheus-stack/README.md` and `apps/keycloak/README.md` for detailed examples.

## TLS Certificate Validation

**IMPORTANT**: Never disable TLS certificate verification (`--insecure`, `verify: false`, `skip_tls_verify`). Always configure applications to trust the cluster CA certificate instead.

The CA is available via the `selfsigned-cluster-issuer-ca` Secret in `cert-manager` namespace. Use External Secrets with `ClusterSecretStore` to sync it to other namespaces (see `apps/external-secrets/README.md`).

## OIDC Authentication

Applications use Keycloak for OIDC authentication. See detailed documentation:
- `apps/keycloak/README.md` - Keycloak setup, client management, realm configuration
- `apps/external-secrets/README.md` - Cross-namespace secret syncing with ClusterSecretStore
- `apps/argocd/README.md`, `apps/prometheus-stack/README.md`, `apps/istio/README.md` - Per-app OIDC config

## Prometheus Monitoring

**MANDATORY**: Always add Prometheus alerts when creating a new application.

**Structure**:
```
apps/<app-name>/kustomize/monitoring/
├── kustomization.yaml
├── prometheusrules.yaml    # PrometheusRule
├── servicemonitors.yaml    # ServiceMonitor (optional)
├── podmonitors.yaml        # PodMonitor (optional)
└── grafana-*.yaml          # Grafana dashboards (optional)
```

**Current Coverage** (maintain >90%):

| Application | Alerts | Status |
|-------------|--------|--------|
| cilium | 10 | Complete |
| longhorn | 9 | Complete |
| istio | 5 | Complete |
| argocd | 13 | Complete |
| metallb | 8 | Complete |
| external-dns | 7 | Complete |
| cert-manager | 6 | Complete |
| kube-vip | 3 | Complete |
| csi-external-snapshotter | 3 | Complete |
| prometheus-stack | 57+ | Complete |
| gateway-api-controller | 2 | Complete |
| tempo | 9 | Complete |
| jaeger | 9 | Complete |

> See `apps/prometheus-stack/README.md` for alert guidelines, severity levels, and examples.

## Environment Differences

- **dev**: RKE2 via Vagrant, auto-sync enabled, 1 replica
- **prod**: HA replicas (3+), manual sync, production-grade settings

## Best Practices & Tips

### Prometheus ServiceMonitor/PodMonitor Discovery

ServiceMonitors and PodMonitors **must** have the label `release: prometheus-stack` to be discovered by Prometheus. Use Kustomize `commonLabels` in `kustomize/monitoring/kustomization.yaml`:

```yaml
commonLabels:
  release: prometheus-stack
```

### Istio Namespace Annotations

Configure Istio behavior per namespace with these annotations/labels:
- `istio-injection: enabled` - Sidecar injection (classic mode)
- `istio.io/dataplane-mode: ambient` - Ambient mesh mode (ztunnel)
- `istio.io/use-waypoint: <waypoint-name>` - L7 processing via waypoint proxy

### Grafana Dashboard Auto-Import

Dashboards are ConfigMaps with specific labels/annotations for auto-import:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_dashboard_folder: "/tmp/dashboards/MyApp"
```

### ArgoCD ignoreDifferences

Common fields to ignore in ApplicationSet `spec.template.spec.ignoreDifferences`:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas  # Managed by HPA
  - group: autoscaling
    kind: HorizontalPodAutoscaler
    jsonPointers:
      - /spec/minReplicas
      - /spec/maxReplicas
```

### Go Template Validation

Test ApplicationSet Go templates locally before pushing:

```bash
# Render ApplicationSet with yq to check syntax
yq eval-all 'select(document_index == 0)' apps/my-app/applicationset.yaml

# Validate with argocd CLI (requires cluster access)
argocd appset generate apps/my-app/applicationset.yaml --dry-run
```

### KSOPS Secret Structure

Standard structure for encrypted secrets:

```yaml
# kustomization.yaml
generators:
  - ksops-generator.yaml

# ksops-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: secret-generator
files:
  - ./secret.yaml

# secret.yaml (encrypted with sops)
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
type: Opaque
stringData:
  key: ENC[AES256_GCM,data:...,type:str]
```

### CiliumNetworkPolicy Pattern

Default-deny egress policy + per-app allow rules:

```yaml
# Default deny (in resources/)
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: default-deny-egress
spec:
  endpointSelector: {}
  egressDeny:
    - toEntities: ["world"]
```

Per-app policies allow specific egress (DNS, APIs, etc.).

### HTTPRoute Structure

HTTPRoutes reference a Gateway and define backends:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
spec:
  parentRefs:
    - name: default-gateway
      namespace: istio-system
  hostnames:
    - "my-app.k8s.lan"
  rules:
    - backendRefs:
        - name: my-app-service
          port: 8080
```

### Multi-Source Application Pattern

Combine Helm chart + Kustomize overlays in one Application:

```yaml
sources:
  - repoURL: https://charts.example.io
    chart: my-app
    targetRevision: "{{ .myApp.version }}"
    helm:
      releaseName: my-app
      valueFiles:
        - $values/deploy/argocd/apps/my-app/resources/values.yaml
  - repoURL: '{{ .git.url }}'
    targetRevision: '{{ .git.revision }}'
    ref: values  # Reference for $values above
  - repoURL: '{{ .git.url }}'
    targetRevision: '{{ .git.revision }}'
    path: deploy/argocd/apps/my-app/kustomize/monitoring
```

### Sync Waves Intra-Application

Use annotations on resources for ordering within an Application (CRDs before CRs):

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # CRDs first
---
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"   # CRs after
```

### PVC Protection

Prevent PVC deletion during sync with resource annotation:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

Or exclude from pruning globally in ApplicationSet `syncPolicy.syncOptions`.

### ArgoCD Finalizers

Control resource cleanup behavior:

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io  # Delete resources when App deleted
    # Or use foreground deletion:
    - resources-finalizer.argocd.argoproj.io/foreground
```

Without finalizer, resources are orphaned when Application is deleted.

## Troubleshooting

### Applications Not Syncing

```bash
kubectl get applicationset -n argo-cd              # Check ApplicationSet exists
kubectl get application -n argo-cd <app> -o yaml   # Check Application generated
kubectl -n argo-cd patch application <app> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'  # Force refresh
```

### Configuration Changes Not Applied

ArgoCD reads from GitHub, not local files. Always `git push` then force refresh.

### StorageClass Not Found

Timing issue - delete the resource and let ArgoCD recreate it after Longhorn is ready.

### Cluster Access Issues

```bash
cd vagrant && K8S_ENV=dev vagrant status           # Check cluster
make vagrant-dev-ssh                               # SSH to master
```

## App-Specific Documentation

Each application has detailed documentation in its README.md:

| Category | Apps with READMEs |
|----------|-------------------|
| Infrastructure | metallb, kube-vip, external-dns |
| Certificates & Secrets | cert-manager, external-secrets |
| Ingress & Gateway API | ingress-nginx, gateway-api-controller, nginx-gateway-fabric, envoy-gateway, traefik, apisix, istio-gateway |
| Service Mesh | istio, cilium |
| Storage | longhorn, csi-external-snapshotter, rook |
| Database | cnpg-operator |
| Monitoring | prometheus-stack |
| Tracing & Logging | tempo, jaeger, alloy, loki |
| Identity & Security | keycloak, oauth2-proxy, neuvector |
| GitOps | argocd |

Path: `deploy/argocd/apps/<app-name>/README.md`
