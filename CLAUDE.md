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
- **Native Go templating** with conditional logic based on `config/config.yaml` flags
- **Per-application configuration** in `deploy/argocd/apps/<app-name>/config/{env}.yaml`
- **Git Merge Generator** combines global + app-specific config

**IMPORTANT**: Always use conditions based on `config/config.yaml` to enable optional features:

| Condition | Usage |
|-----------|-------|
| `{{- if .features.monitoring.enabled }}` | kustomize/monitoring/, ServiceMonitor params |
| `{{- if .features.gatewayAPI.httpRoute.enabled }}` | kustomize/httproute/ |
| `{{- if .features.oauth2Proxy.enabled }}` | kustomize/oauth2-authz/ |
| `{{- if .features.cilium.egressPolicy.enabled }}` | resources/cilium-egress-policy.yaml |
| `{{- if .features.cilium.ingressPolicy.enabled }}` | resources/default-deny-host-ingress.yaml |
| `{{- if .features.sso.enabled }}` | secrets/, ExternalSecret, KeycloakClient |
| `{{- if .features.tracing.enabled }}` | tracing config (Tempo/Jaeger) |
| `{{- if .features.serviceMesh.enabled }}` | service mesh integration |
| `{{- if .features.ingress.enabled }}` | Ingress config |
| `{{- if .features.certManager.enabled }}` | TLS annotations |
| `{{- if .syncPolicy.automated.enabled }}` | automated sync block |

**Combined conditions** (use `and`/`eq` for provider-specific logic):
- `{{- if and .features.sso.enabled (eq .features.sso.provider "keycloak") }}`
- `{{- if and .features.serviceMesh.enabled (eq .features.serviceMesh.provider "istio") }}`
- `{{- if and .features.storage.enabled .persistence.enabled }}` (storage + app persistence)

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

Applications are deployed in order using ArgoCD sync waves (lower = earlier):
- **Inter-app**: `argocd.argoproj.io/sync-wave` annotation on ApplicationSet
- **Intra-app**: Same annotation on individual resources (e.g., CRDs wave `-1`, CRs wave `1`)

### Feature Flags

Feature flags in `config/config.yaml` control which ApplicationSets are deployed.

Examples:
- `features.metallb.enabled` → metallb (wave 10)
- `features.monitoring.enabled` → prometheus-stack (wave 75)
- `features.sso.enabled` + `provider=keycloak` → keycloak (wave 80)

See `deploy-applicationsets.sh` for the complete list and automatic dependency resolution (e.g., `sso.provider=keycloak` enables `databaseOperator`, `externalSecrets`, `certManager`).

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
7. **Create `README.md`** in the app directory (see Documentation section)

### Documentation Updates

**MANDATORY**: Always update documentation when modifying applications.

When modifying an application:
1. **Update `apps/<app-name>/README.md`** - Document any configuration changes, new features, or breaking changes
2. **Update `README.md` (root)** - If the change affects the project structure, available apps, or general usage

When adding a new application:
1. **Create `apps/<app-name>/README.md`** - Document purpose, configuration options, dependencies, and usage examples

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

**Structure**: `apps/<app-name>/kustomize/monitoring/` with `prometheusrules.yaml`, `servicemonitors.yaml`, `grafana-*.yaml`.

See `apps/prometheus-stack/README.md` for alert guidelines and examples.

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

Dashboards are ConfigMaps with labels `grafana_dashboard: "1"` and annotation `grafana_dashboard_folder: "/tmp/dashboards/MyApp"`.

### ArgoCD ignoreDifferences

Use `spec.template.spec.ignoreDifferences` to ignore fields managed externally (e.g., `/spec/replicas` for HPA-managed Deployments).

### Go Template Validation

Test ApplicationSet Go templates locally before pushing:

```bash
# Render ApplicationSet with yq to check syntax
yq eval-all 'select(document_index == 0)' apps/my-app/applicationset.yaml

# Validate with argocd CLI (requires cluster access)
argocd appset generate apps/my-app/applicationset.yaml --dry-run
```

### KSOPS Secret Structure

Structure: `kustomization.yaml` (with `generators: [ksops-generator.yaml]`) → `ksops-generator.yaml` (references `secret.yaml`) → `secret.yaml` (SOPS-encrypted).

### CiliumNetworkPolicy Pattern

**Egress policies** (pod → external):
1. **`apps/cilium/resources/default-deny-external-egress.yaml`** - `CiliumClusterwideNetworkPolicy` (blocks egress to world by default, allows internal cluster traffic)
2. **`apps/argocd/resources/cilium-egress-policy.yaml`** - `CiliumNetworkPolicy` (allows ArgoCD to reach Git repos and Helm registries)

Then each application needing external access defines its own `CiliumNetworkPolicy` in `resources/cilium-egress-policy.yaml`.

**Host firewall policies** (external → node):
1. **`apps/cilium/resources/default-deny-host-ingress.yaml`** - `CiliumClusterwideNetworkPolicy` with `nodeSelector` (blocks external ingress to nodes, allows SSH 22, API 6443, HTTP/HTTPS 80/443, ICMP)

Applications needing additional host ports define their own `CiliumClusterwideNetworkPolicy` with `nodeSelector`.

### HTTPRoute Structure

HTTPRoutes reference a Gateway (`parentRefs` → `default-gateway` in `istio-system`) with `hostnames` and `backendRefs` to services.

### Multi-Source Application Pattern

Combine Helm chart + Kustomize overlays using multiple `sources`: Helm source with `$values` reference, Git source with `ref: values`, and additional Kustomize paths.

### PVC Protection

Prevent PVC deletion with annotation `argocd.argoproj.io/sync-options: Prune=false` on the resource or globally in `syncPolicy.syncOptions`.

### ArgoCD Finalizers

Add `resources-finalizer.argocd.argoproj.io` finalizer to delete resources when Application is deleted (without it, resources are orphaned).

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

Each application has detailed documentation: `deploy/argocd/apps/<app-name>/README.md`
