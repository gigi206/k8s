# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitOps infrastructure project that manages Kubernetes applications using ArgoCD with ApplicationSet pattern. The infrastructure supports multiple environments (dev/prod) with centralized configuration, Go templating, and per-application overrides.

## Prerequisites

- **mise**: For managing tool versions (yq, etc.)
- **yq**: For parsing YAML configuration (installed via mise)
- **kubectl**: For cluster interaction
- **helm**: For chart management
- **kustomize**: For manifest customization
- **argocd**: For ArgoCD interaction
- **yamllint**: For YAML style checking
- **vagrant**: For local cluster creation (dev environment)
- **age**: For AGE encryption keys (installed via mise)
- **sops**: For encrypting/decrypting secrets (installed via mise)

## Key Architecture Concepts

### ApplicationSet-Based Application Management

This project uses ArgoCD ApplicationSets to declaratively manage applications:
- **One ApplicationSet per application** in its own directory (`deploy/argocd/apps/<app-name>/applicationset.yaml`)
- **Native Go templating** with conditional logic (`{{ if .features.monitoring.enabled }}`)
- **Per-application configuration** in `deploy/argocd/apps/<app-name>/config/{env}.yaml`
- **Git Merge Generator** reads global + app-specific config and generates Applications
- **Bootstrap Application** creates all ApplicationSets from a directory pattern

### Configuration Hierarchy

1. **Global Config**: `deploy/argocd/config/config.yaml` (shared defaults, feature flags, common variables)
2. **App-Specific Config**: `deploy/argocd/apps/<app-name>/config/dev.yaml` or `prod.yaml` (app settings + **chart version**)
3. **ApplicationSet**: `deploy/argocd/apps/<app-name>/applicationset.yaml` (templates the Application)
4. **Resources**: `deploy/argocd/apps/<app-name>/resources/` (K8s manifests, values files, etc.)

The Merge Generator combines global config + app config, then ApplicationSet uses Go templates to generate the final Application.

### Version Management

**IMPORTANT**: Each application manages its own Helm chart version in its config files. This enables Renovate/Dependabot to automatically update versions.

**Version location**: `apps/<app-name>/config/dev.yaml` and `prod.yaml`

**Example**:
```yaml
# apps/metallb/config/dev.yaml
environment: dev
appName: metallb

metallb:
  version: "0.15.3"  # Helm chart version - Renovate will update this
  ipAddressPool:
    - name: default
      addresses:
        - 192.168.121.220-192.168.121.250
```

**ApplicationSet reference**: `{{ .metallb.version }}` (not `{{ .versions.metallb }}`)

**Apps with multiple charts** (e.g., external-dns with coredns and etcd):
```yaml
# apps/external-dns/config/dev.yaml
externalDns:
  versions:
    chart: "1.19.0"    # main external-dns chart
    coredns: "1.45.0"  # coredns chart
    etcd: "1.1.4"      # etcd chart
```

### Automated Version Updates with Renovate

This project uses [Renovate](https://docs.renovatebot.com/) to automatically create PRs for dependency updates. The configuration is in `renovate.json` at the repository root.

**How it works**:
- Renovate uses custom regex managers to detect versions in `apps/<app>/config/*.yaml`
- Each app's version is mapped to its corresponding Helm repository or GitHub releases
- PRs are created automatically when new versions are available

**Supported datasources**:
| App Type | Datasource | Example |
|----------|------------|---------|
| Helm charts | `helm` | metallb, argocd, prometheus-stack |
| GitHub releases | `github-releases` | gateway-api, csi-snapshotter, nginx-gateway-fabric |
| OCI registries | `helm` (OCI) | envoy-gateway |

**Schedule**: Updates are checked weekly (Monday before 6am) to avoid disruption.

**Automerge**: Patch updates are automatically merged for ArgoCD apps to reduce maintenance burden.

**Adding a new app to Renovate**:
1. Add version to the app's config file: `<appName>.version: "X.X.X"`
2. Add a new `customManagers` entry in `renovate.json`:
```json
{
  "customType": "regex",
  "description": "My App Helm chart",
  "fileMatch": ["^deploy/argocd/apps/my-app/config/.*\\.yaml$"],
  "matchStrings": ["myApp:\\s*\\n\\s*version:\\s*\"(?<currentValue>[^\"]+)\""],
  "depNameTemplate": "my-app",
  "datasourceTemplate": "helm",
  "registryUrlTemplate": "https://charts.example.com"
}
```

### Directory Structure per Application

```
deploy/argocd/apps/<app-name>/
├── applicationset.yaml      # ApplicationSet definition with Go templates
├── config/
│   ├── dev.yaml            # Dev environment configuration
│   └── prod.yaml           # Prod environment configuration
└── resources/              # Optional: K8s manifests, Helm values, etc.
    ├── values.yaml
    ├── prometheus.yaml
    └── grafana-dashboard.yaml
```

### Deployment Flow

```
deploy-applicationsets.sh script
  → Creates sops-age-key secret (from sops/age-{env}.key)
  → Reads feature flags from config/config.yaml
  → Resolves dependencies automatically (e.g., Keycloak → CNPG + External-Secrets)
  → Builds dynamic ApplicationSet list based on enabled features
  → Uses `yq` to parse configuration (installed via `mise`)
  → Each ApplicationSet uses Git Merge Generator:
      - Reads deploy/argocd/config/config.yaml (global)
      - Reads deploy/argocd/apps/<app-name>/config/*.yaml (app-specific)
      - Merges configs by "environment" key
  → Go template evaluation (conditions, variables)
  → Generates ArgoCD Application per environment
  → ArgoCD deploys apps via sync waves
  → KSOPS decrypts secrets from apps/<app>/secrets/*.yaml
  → Patches Ingress resources (if any) with configured ingress class
```

ApplicationSets are dynamically selected based on feature flags in `config.yaml`. The script automatically resolves dependencies between components.

### Sync Wave Strategy

Applications deploy in order via `argocd.argoproj.io/sync-wave` annotations:
- **Wave 10**: MetalLB (LoadBalancer)
- **Wave 15**: Gateway-API-Controller, Kube-VIP (API HA)
- **Wave 20**: Cert-Manager (TLS certificates)
- **Wave 30**: External-DNS (DNS automation)
- **Wave 40**: Istio (Service Mesh)
- **Wave 41**: Istio-Gateway (Ingress Gateway)
- **Wave 50**: ArgoCD (self-management)
- **Wave 55**: CSI-External-Snapshotter (volume snapshots)
- **Wave 60**: Longhorn (distributed storage)
- **Wave 65**: CNPG-Operator (PostgreSQL operator)
- **Wave 73**: Loki (log storage and querying)
- **Wave 74**: Alloy (log collector DaemonSet)
- **Wave 75**: Prometheus-Stack (monitoring) - higher wave to ensure Longhorn StorageClass is ready
- **Wave 76**: Cilium-Monitoring (ServiceMonitors for Cilium/Hubble) - after prometheus-stack
- **Wave 77**: Jaeger (distributed tracing) + Waypoint proxies - after monitoring for trace visualization
- **Wave 80**: Keycloak (SSO/Identity Provider)
- **Wave 81**: OAuth2-Proxy (ext_authz authentication)

**Note**: Prometheus-Stack is in Wave 75 (not 70) to give Longhorn time to fully initialize the StorageClass before Prometheus tries to create PVCs. Cilium-Monitoring is in Wave 76 to ensure Prometheus CRDs are available. Jaeger is in Wave 77 to ensure monitoring is ready for trace visualization in Kiali/Grafana.

### Feature Flags and Dynamic Deployment

The `deploy-applicationsets.sh` script dynamically selects which ApplicationSets to deploy based on feature flags in `config/config.yaml`. This allows flexible infrastructure configurations.

#### Feature Flags Structure

```yaml
# deploy/argocd/config/config.yaml
features:
  # Infrastructure Core
  metallb:
    enabled: true           # Wave 10: LoadBalancer Layer 2
  kubeVip:
    enabled: true           # Wave 15: VIP for Kubernetes API HA

  # Certificates & Secrets
  certManager:
    enabled: true           # Wave 20: TLS certificate management
  externalSecrets:
    enabled: true           # Wave 25: External Secrets Operator

  # DNS
  externalDns:
    enabled: true           # Wave 30: DNS automation

  # Service Mesh
  serviceMesh:
    enabled: true           # Wave 40: Service Mesh control plane
    provider: "istio"       # istio, linkerd (future)

  # Gateway API
  gatewayAPI:
    enabled: true           # Wave 15: Gateway API CRDs
    httpRoute:
      enabled: true         # Enable HTTPRoute resources
    controller:
      provider: "istio"     # Wave 41: istio, nginx-gateway-fabric, envoy-gateway, apisix, traefik, nginx

  # Storage
  storage:
    enabled: true           # Wave 60: Distributed storage
    provider: "longhorn"    # longhorn
    csiSnapshotter: true    # Wave 55: CSI snapshots

  # Database Operator
  databaseOperator:
    enabled: true           # Wave 65: PostgreSQL operator
    provider: "cnpg"        # cnpg (CloudNativePG)

  # Monitoring
  monitoring:
    enabled: true           # Wave 75: Prometheus + Grafana
  cilium:
    monitoring:
      enabled: true         # Wave 76: Cilium/Hubble metrics

  # Logging
  logging:
    enabled: true           # Active le logging centralisé
    loki:
      enabled: true         # Wave 73: Grafana Loki
      collector: "alloy"    # Wave 74: alloy (recommandé)

  # Distributed Tracing
  tracing:
    enabled: true           # Wave 77: Jaeger distributed tracing
    provider: "jaeger"      # jaeger (only supported provider)
    waypoints:
      enabled: true         # Deploy Istio Waypoint proxies for L7 tracing
      namespaces:           # Namespaces to enable L7 tracing via Waypoints
        - monitoring
        - keycloak
        - oauth2-proxy

  # SSO / Authentication
  sso:
    enabled: true           # Wave 80: Identity Provider
    provider: "keycloak"    # keycloak or external (external IdP)
  oauth2Proxy:
    enabled: true           # Wave 81: OAuth2 Proxy for OIDC
```

#### Automatic Dependency Resolution

The script automatically enables dependencies when required:

| Feature Enabled | Automatically Enables |
|-----------------|----------------------|
| `sso.provider=keycloak` | `databaseOperator`, `externalSecrets`, `certManager` |
| `gatewayAPI.controller.provider=istio` | `serviceMesh` (istio), `gatewayAPI` |
| `gatewayAPI.controller.provider=nginx-gateway-fabric/envoy-gateway/apisix/traefik` | `gatewayAPI` |
| `cilium.monitoring.enabled` | `monitoring` |
| `storage.provider=longhorn` | `storage.csiSnapshotter` (recommended) |
| `tracing.waypoints.enabled` | `serviceMesh` (istio), `gatewayAPI` |

**Example**: If you set `sso.enabled=true` with `sso.provider=keycloak` but `databaseOperator.enabled=false`, the script will automatically enable `databaseOperator`, `externalSecrets`, and `certManager` because Keycloak requires them.

#### Feature Flag to ApplicationSet Mapping

| Feature Flag | ApplicationSet | Wave |
|-------------|----------------|------|
| `metallb.enabled` | metallb | 10 |
| `kubeVip.enabled` | kube-vip | 15 |
| `gatewayAPI.enabled` | gateway-api-controller | 15 |
| `certManager.enabled` | cert-manager | 20 |
| `externalSecrets.enabled` | external-secrets | 25 |
| `externalDns.enabled` | external-dns | 30 |
| `serviceMesh.enabled` + `provider=istio` | istio | 40 |
| `gatewayAPI.controller.provider=istio` | istio-gateway | 41 |
| `gatewayAPI.controller.provider=nginx-gateway-fabric` | nginx-gateway-fabric | 41 |
| *(always)* | argocd | 50 |
| `storage.csiSnapshotter` | csi-external-snapshotter | 55 |
| `storage.enabled` + `provider=longhorn` | longhorn | 60 |
| `databaseOperator.enabled` + `provider=cnpg` | cnpg-operator | 65 |
| `logging.enabled` + `logging.loki.enabled` | loki | 73 |
| `logging.enabled` + `logging.loki.collector=alloy` | alloy | 74 |
| `monitoring.enabled` | prometheus-stack | 75 |
| `cilium.monitoring.enabled` | cilium-monitoring | 76 |
| `tracing.enabled` + `provider=jaeger` | jaeger | 77 |
| `sso.enabled` + `provider=keycloak` | keycloak | 80 |
| `oauth2Proxy.enabled` | oauth2-proxy | 81 |

#### Example Configurations

**Minimal Configuration** (8 apps - no SSO, basic ingress):
```yaml
features:
  metallb: { enabled: true }
  kubeVip: { enabled: false }
  gatewayAPI: { enabled: true, controller: { provider: nginx } }
  certManager: { enabled: true }
  externalSecrets: { enabled: false }
  externalDns: { enabled: false }
  serviceMesh: { enabled: false }
  storage: { enabled: true, provider: longhorn, csiSnapshotter: true }
  monitoring: { enabled: true }
  cilium: { monitoring: { enabled: false } }
  logging: { enabled: false }
  tracing: { enabled: false }
  databaseOperator: { enabled: false }
  sso: { enabled: false }
  oauth2Proxy: { enabled: false }
```

**Full Configuration** (19 apps - all features):
```yaml
features:
  metallb: { enabled: true }
  kubeVip: { enabled: true }
  gatewayAPI: { enabled: true, httpRoute: { enabled: true }, controller: { provider: istio } }
  certManager: { enabled: true }
  externalSecrets: { enabled: true }
  externalDns: { enabled: true }
  serviceMesh: { enabled: true, provider: istio }
  storage: { enabled: true, provider: longhorn, csiSnapshotter: true }
  monitoring: { enabled: true }
  cilium: { monitoring: { enabled: true } }
  logging: { enabled: true, loki: { enabled: true, collector: alloy } }
  tracing: { enabled: true, provider: jaeger, waypoints: { enabled: true } }
  databaseOperator: { enabled: true, provider: cnpg }
  sso: { enabled: true, provider: keycloak }
  oauth2Proxy: { enabled: true }
```

## Current Applications (Dev Environment)

With full configuration (all features enabled), 19 applications are deployed:

1. **metallb** - Layer 2 LoadBalancer (192.168.121.220-250)
2. **kube-vip** - VIP for Kubernetes API (192.168.121.200)
3. **gateway-api-controller** - Gateway API CRDs
4. **cert-manager** - Certificate management (self-signed issuer in dev)
5. **external-secrets** - External Secrets Operator
6. **external-dns** - DNS automation with CoreDNS
7. **istio** - Service Mesh (Ambient mode) + Kiali
8. **istio-gateway** - Ingress Gateway
9. **argocd** - GitOps controller (self-managed, OIDC auth)
10. **csi-external-snapshotter** - Snapshot CRDs for Longhorn
11. **longhorn** - Distributed block storage
12. **cnpg-operator** - CloudNativePG PostgreSQL operator
13. **loki** - Log storage and querying (Grafana Loki)
14. **alloy** - Log collector DaemonSet (Grafana Alloy)
15. **prometheus-stack** - Prometheus, Grafana (OIDC auth), Alertmanager
16. **cilium-monitoring** - ServiceMonitors for Cilium/Hubble metrics
17. **jaeger** - Distributed tracing (all-in-one mode in dev) + Waypoint proxies
18. **keycloak** - Identity and Access Management (OIDC provider)
19. **oauth2-proxy** - OAuth2 Proxy for ext_authz authentication

## Common Development Commands

### Full Environment Setup

```bash
# From project root - installs Vagrant cluster + ArgoCD + all apps
make dev-full

# Or step by step:
make vagrant-dev-up          # Create Vagrant/RKE2 cluster
make argocd-install-dev      # Install ArgoCD + deploy ApplicationSets
```

### Deploy ApplicationSets (First Time or After Clean Install)

Deployment is automatically done by `make argocd-install-dev`, but you can do it manually:

```bash
# Deploy all ApplicationSets via the script
cd deploy/argocd
bash deploy-applicationsets.sh

# The script reads feature flags from config/config.yaml and dynamically
# builds the list of ApplicationSets to deploy. Use -v for verbose output.
bash deploy-applicationsets.sh -v
```

The script automatically:
1. Reads feature flags from `config/config.yaml`
2. Resolves dependencies (e.g., Keycloak → CNPG + External-Secrets + Cert-Manager)
3. Builds the ApplicationSet list based on enabled features
4. Deploys only the required ApplicationSets

### Deploy/Update Applications

```bash
# After bootstrap, everything is managed via Git:
# 1. Edit configuration files
vim deploy/argocd/apps/prometheus-stack/config/dev.yaml

# 2. Commit and push
git add deploy/argocd/apps/prometheus-stack/config/dev.yaml
git commit -m "Update Prometheus retention"
git push

# 3. ArgoCD automatically detects and applies changes (dev has auto-sync enabled)
```

### Cluster Management (Vagrant/RKE2)

```bash
# From root directory
make vagrant-dev-up          # Create cluster only
make vagrant-dev-status      # Check cluster status
make vagrant-dev-ssh         # SSH to master node
make vagrant-dev-destroy     # Delete cluster

# Full environment lifecycle
make dev-full                # Create + install everything
make vagrant-dev-destroy     # Clean up
```

### KUBECONFIG Management

```bash
# Dev environment kubeconfig is at:
export KUBECONFIG=/path/to/vagrant/.kube/config-dev

# After Kube-VIP is deployed, deploy-applicationsets.sh automatically updates
# the kubeconfig to use the VIP (192.168.121.200) instead of a node IP
```

### Monitoring Deployment

```bash
# Check applications status
kubectl get applications -n argo-cd

# Check ApplicationSets
kubectl get applicationsets -n argo-cd

# Watch a specific app sync
kubectl get application -n argo-cd prometheus-stack -w

# Force sync an application
kubectl -n argo-cd patch application prometheus-stack --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Working with Configuration

### Modifying an Application

1. Edit the app-specific config file:
```yaml
# deploy/argocd/apps/prometheus-stack/config/dev.yaml
environment: dev
appName: prometheus-stack

prometheusStack:
  prometheus:
    retention: "14d"      # Change from 7d to 14d
    storageSize: "10Gi"   # Change from 5Gi to 10Gi
```

2. Commit and push to Git
3. ArgoCD auto-syncs (dev env) or manually sync (prod env)

### Adding a New Application

1. Create application directory:
```bash
mkdir -p deploy/argocd/apps/my-app/{config,resources}
```

2. Copy and customize ApplicationSet:
```bash
# Use an existing app as template (e.g., longhorn or ingress-nginx)
cp deploy/argocd/apps/longhorn/applicationset.yaml \
   deploy/argocd/apps/my-app/applicationset.yaml
```

3. Create config files:
```yaml
# deploy/argocd/apps/my-app/config/dev.yaml
---
environment: dev
appName: my-app

myApp:
  replicas: 1
  image: my-app:latest

syncPolicy:
  automated:
    enabled: true
    prune: true
    selfHeal: true
```

4. Add resources if needed:
```bash
# Optional: add custom manifests, values files, etc.
deploy/argocd/apps/my-app/resources/values.yaml
```

5. Add to deployment script (for automatic deployment):
```bash
# Edit deploy/argocd/deploy-applicationsets.sh
# Add to APPLICATIONSETS array (line ~267):
  "apps/my-app/applicationset.yaml"   # Wave XX

# Or deploy manually:
kubectl apply -f deploy/argocd/apps/my-app/applicationset.yaml
```

6. **IMPORTANT: Add Prometheus alerts** (see Prometheus Monitoring section below)

7. Commit and push

### Feature Flags and Conditional Deployment

Use Go templating in ApplicationSet to conditionally deploy resources:

```yaml
# In applicationset.yaml
templatePatch: |
  spec:
    sources:
      {{- if .features.monitoring.enabled }}
      # Source 2: Prometheus monitoring (conditional)
      - repoURL: https://github.com/gigi206/k8s
        targetRevision: '{{ .git.revision }}'
        path: deploy/argocd/apps/my-app/resources
        directory:
          include: "prometheus.yaml"
      {{- end }}
```

Control features in global config:
```yaml
# deploy/argocd/config/config.yaml
features:
  monitoring:
    enabled: true
    release: "prometheus-stack"  # Used for ServiceMonitor discovery
  ingress:
    enabled: true
    class: "nginx"
  certManager:
    enabled: true
  storage:
    class: "longhorn"
```

### ⚠️ IMPORTANT: Go Template Variable Limitations

**CRITICAL**: Go templates (`{{ .variable }}`) **ONLY work in ApplicationSet definitions**, NOT in manifest YAML files.

**Where Go templates work**:
- ✅ ApplicationSet `template` section
- ✅ ApplicationSet `templatePatch` section
- ✅ Helm `parameters` (as strings passed to Helm)

**Where Go templates DON'T work**:
- ❌ YAML manifests in `resources/` or `kustomize/` directories
- ❌ Helm values files (use Helm's own templating instead)
- ❌ Raw Kubernetes manifests loaded via directory sources

**Solutions for using variables in manifests**:
1. **Kustomize replacements**: Define replacements in kustomization.yaml
2. **Helm charts**: Use Helm's template syntax with values
3. **Hardcode values**: Simple approach for static values (domain, ingressClass, etc.)

**Example - WRONG** (Go templates in manifest):
```yaml
# ❌ apps/my-app/resources/ingress.yaml - WON'T WORK
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  ingressClassName: {{ .features.ingress.class }}  # ❌ NOT evaluated!
  rules:
  - host: myapp.{{ .common.domain }}  # ❌ NOT evaluated!
```

**Example - CORRECT** (hardcoded values or Kustomize):
```yaml
# ✅ apps/my-app/kustomize/ingress.yaml - WORKS
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  ingressClassName: istio  # ✅ Hardcoded or use Kustomize replacements
  rules:
  - host: myapp.k8s.lan  # ✅ Hardcoded
```

### ServiceMonitors and PrometheusRules with Kustomize

**Pattern**: Use Kustomize `commonLabels` to inject dynamic labels (like `release: prometheus-stack`) instead of hardcoding values.

**Why**: Ensures consistency across all monitoring resources and uses centralized configuration (`features.monitoring.release` from `config.yaml`).

**Structure**:
```
my-app/
├── applicationset.yaml
├── config/
│   ├── dev.yaml
│   └── prod.yaml
└── kustomize/
    ├── kustomization.yaml
    └── prometheus.yaml  # ServiceMonitor and/or PrometheusRule
```

**Example** (`kustomize/prometheus.yaml`):
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: my-namespace
  # Note: 'release' label injected by Kustomize via commonLabels
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
  - port: metrics
    interval: 30s
```

**Kustomization** (`kustomize/kustomization.yaml`):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - prometheus.yaml
```

**ApplicationSet configuration**:
```yaml
templatePatch: |
  spec:
    sources:
      - repoURL: https://github.com/gigi206/k8s
        targetRevision: '{{ .git.revision }}'
        path: deploy/argocd/apps/my-app/kustomize
        kustomize:
          commonLabels:
            release: '{{ .features.monitoring.release }}'
```

**Applications using this pattern**:
- argocd, metallb, external-dns, cert-manager, ingress-nginx, longhorn (PrometheusRules)
- cilium-monitoring, prometheus-stack (ServiceMonitors and PrometheusRules)

### Secrets Management with SOPS/KSOPS

**Overview**: Secrets are encrypted in Git using SOPS with AGE encryption. ArgoCD decrypts them at deploy time using KSOPS (Kustomize plugin).

**Architecture**:
```
Git Repository                          ArgoCD Repo Server
+------------------------+              +---------------------------+
| .sops.yaml (pub keys)  |              | KSOPS plugin (init cont.) |
| apps/<app>/secrets/    |  ──────────> | AGE private key (volume)  |
|   ├── dev/secret.yaml  |              | SOPS_AGE_KEY_FILE env     |
|   └── prod/secret.yaml |              +---------------------------+
+------------------------+                         │
                                                   v
                                         Decrypted K8s Secret
```

**Key Files**:
- `sops/age-dev.key` - AGE private key for dev (used by ArgoCD to decrypt)
- `sops/age-prod.key` - AGE private key for prod
- `deploy/argocd/.sops.yaml` - SOPS config with public keys and encryption rules

> **⚠️ Note**: The private keys in `sops/` are stored in plaintext in the repository.
> This is intentional for this **demo cluster**. In production, private keys should
> be stored securely (e.g., in a password manager, HSM, or injected via CI/CD secrets)
> and **never committed to Git**.

**Directory Structure for Secrets**:
```
deploy/argocd/apps/<app-name>/
├── applicationset.yaml
├── config/
│   ├── dev.yaml
│   └── prod.yaml
├── kustomize/              # Monitoring resources
└── secrets/                # Encrypted secrets
    ├── dev/                # Dev environment secrets
    │   ├── kustomization.yaml
    │   ├── ksops-generator.yaml
    │   └── secret.yaml     # Encrypted with dev public key
    └── prod/               # Prod environment secrets
        ├── kustomization.yaml
        ├── ksops-generator.yaml
        └── secret.yaml     # Encrypted with prod public key
```

**Adding Secrets to an Application**:

1. **Create secrets directories** (one per environment):
```bash
mkdir -p deploy/argocd/apps/<app-name>/secrets/{dev,prod}
```

2. **Create kustomization.yaml** (in each env directory):
```yaml
# deploy/argocd/apps/<app-name>/secrets/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - ksops-generator.yaml
```

3. **Create ksops-generator.yaml** (in each env directory):
```yaml
# deploy/argocd/apps/<app-name>/secrets/dev/ksops-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: <app-name>-secrets
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secret.yaml
```

4. **Create secret file** (before encryption):
```yaml
# deploy/argocd/apps/<app-name>/secrets/dev/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: <app-name>-credentials
  namespace: <app-namespace>
type: Opaque
stringData:
  username: myuser
  password: mypassword
```

5. **Encrypt the secret**:
```bash
cd deploy/argocd
sops encrypt --in-place apps/<app-name>/secrets/dev/secret.yaml
sops encrypt --in-place apps/<app-name>/secrets/prod/secret.yaml
```

6. **Add secrets source to ApplicationSet** (with environment-specific path):
```yaml
templatePatch: |
  spec:
    sources:
      # Source: Encrypted secrets (KSOPS) - environment-specific
      - repoURL: https://github.com/gigi206/k8s
        targetRevision: '{{ .git.revision }}'
        path: deploy/argocd/apps/<app-name>/secrets/{{ .environment }}
      # ... other sources
```

7. **Reference the secret in Helm values** (example for Grafana):
```yaml
# Instead of:
- name: grafana.adminPassword
  value: 'plaintext-password'

# Use:
- name: grafana.admin.existingSecret
  value: grafana-admin-credentials
- name: grafana.admin.userKey
  value: admin-user
- name: grafana.admin.passwordKey
  value: admin-password
```

**Managing Secrets Locally**:
```bash
# Decrypt a secret for editing
sops decrypt apps/<app>/secrets/secret-dev.yaml

# Edit in place (opens in $EDITOR)
sops apps/<app>/secrets/secret-dev.yaml

# Re-encrypt after editing
sops encrypt --in-place apps/<app>/secrets/secret-dev.yaml
```

**Applications using SOPS/KSOPS**:
- prometheus-stack (Grafana admin credentials)
- keycloak (OIDC client secrets for ArgoCD, Grafana, Kiali)

## OIDC Authentication with Keycloak

### Overview

Applications are secured with OIDC authentication via Keycloak. The authentication flow uses:
- **Keycloak** as the Identity Provider (realm: k8s`)
- **Automatic client creation** via Kubernetes Jobs (PostSync hooks)
- **Cross-namespace secret syncing** via ExternalSecrets + ClusterSecretStore

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Keycloak (namespace: keycloak)               │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
│  │ argocd-oidc-    │  │ grafana-oidc-   │  │ kiali-oidc-     │     │
│  │ client-secret   │  │ client-secret   │  │ client-secret   │     │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘     │
└───────────┼─────────────────────┼─────────────────────┼─────────────┘
            │ ClusterSecretStore  │                     │
            │ (keycloak-oidc-     │                     │
            │  secrets)           │                     │
            ▼                     ▼                     ▼
┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│   argo-cd ns      │ │   monitoring ns   │ │  istio-system ns  │
│ ┌───────────────┐ │ │ ┌───────────────┐ │ │ ┌───────────────┐ │
│ │ argocd-secret │ │ │ │grafana-oidc-  │ │ │ │    kiali      │ │
│ │ (ExternalSec) │ │ │ │credentials    │ │ │ │ (ExternalSec) │ │
│ └───────────────┘ │ │ └───────────────┘ │ │ └───────────────┘ │
└───────────────────┘ └───────────────────┘ └───────────────────┘
```

### Applications with OIDC Authentication

| Application | Client ID | Auth Strategy | Notes |
|-------------|-----------|---------------|-------|
| ArgoCD | `argocd` | OIDC | Dex connector |
| Grafana | `grafana` | OAuth2 | Auto-login enabled, anonymous disabled |
| Kiali | `kiali` | OpenID | Service mesh UI |

### Adding OIDC Authentication to a New Application

1. **Create SOPS-encrypted client secret** in `keycloak/secrets/dev/`:
```bash
# Create secret file
cat > /tmp/secret-myapp-client.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: myapp-oidc-client-secret
  namespace: keycloak
type: Opaque
stringData:
  client-secret: my-random-secret-value
EOF

# Copy and encrypt
cp /tmp/secret-myapp-client.yaml deploy/argocd/apps/keycloak/secrets/dev/secret-myapp-client.yaml
cd deploy/argocd && sops encrypt -i apps/keycloak/secrets/dev/secret-myapp-client.yaml
```

2. **Add to ksops-generator.yaml**:
```yaml
# apps/keycloak/secrets/dev/ksops-generator.yaml
files:
  - ./secret.yaml
  - ./secret-argocd-client.yaml
  - ./secret-grafana-client.yaml
  - ./secret-kiali-client.yaml
  - ./secret-myapp-client.yaml  # Add this
```

3. **Create Keycloak client Job** in `myapp/resources/keycloak-client.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: myapp-keycloak-client
  namespace: keycloak
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: create-client
          image: curlimages/curl:8.5.0
          env:
            - name: KEYCLOAK_URL
              value: "https://keycloak.k8s.lan"
            - name: REALM
              value: "k8s"
            - name: CLIENT_ID
              value: "myapp"
            - name: KEYCLOAK_ADMIN
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin-credentials
                  key: username
            - name: KEYCLOAK_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin-credentials
                  key: password
            - name: CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: myapp-oidc-client-secret
                  key: client-secret
          command: ["/bin/sh", "-c"]
          args:
            - |
              # Script to create/update Keycloak client via Admin API
              # See existing examples in argocd/prometheus-stack/istio
```

4. **Create ExternalSecret** to sync secret to target namespace:
```yaml
# apps/myapp/resources/external-secret-oidc.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-oidc-external
  namespace: myapp-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: keycloak-oidc-secrets
  target:
    name: myapp-oidc-credentials
    creationPolicy: Owner
  data:
    - secretKey: client-secret
      remoteRef:
        key: myapp-oidc-client-secret
        property: client-secret
```

5. **Configure application** with OIDC settings in `config/dev.yaml`

### ClusterSecretStore for Cross-Namespace Secrets

The `keycloak-oidc-secrets` ClusterSecretStore allows any namespace to read secrets from the `keycloak` namespace:

```yaml
# apps/keycloak/resources/cluster-secret-store.yaml
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

### Kiali-Specific: Grafana Integration with Mounted Secrets

The kiali-server Helm chart requires secrets to be mounted via `deployment.custom_secrets` (the `secret:` syntax alone doesn't work):

```yaml
# In ApplicationSet templatePatch
deployment:
  custom_secrets:
    - name: kiali-grafana-username
      mount: /kiali-override-secrets/grafana-username
    - name: kiali-grafana-password
      mount: /kiali-override-secrets/grafana-password

external_services:
  grafana:
    auth:
      type: basic
      username: secret:kiali-grafana-username:value.txt
      password: secret:kiali-grafana-password:value.txt
```

**Important**: The secrets must have a key named `value.txt`. Use ExternalSecrets to create them:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: kiali-grafana-password
  namespace: istio-system
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: grafana-secrets
  target:
    name: kiali-grafana-password
  data:
    - secretKey: value.txt  # Must be value.txt!
      remoteRef:
        key: grafana-admin-credentials
        property: admin-password
```

See: https://kiali.io/docs/faq/installation/

## Prometheus Monitoring and Alerts

### ⚠️ MANDATORY: Always Add Prometheus Alerts for New Applications

**CRITICAL RULE**: When adding a new application to the cluster, you MUST systematically create Prometheus alerts to monitor its health and performance. This is not optional.

**Why this is mandatory**:
- **Proactive monitoring**: Detect issues before they impact users
- **Observability**: Maintain complete visibility of the cluster infrastructure
- **SRE best practices**: Every component should have alerting coverage
- **Current coverage**: 10/11 applications have alerts (91% coverage) - maintain this standard

### Steps to Add Prometheus Alerts for a New Application

1. **Create the PrometheusRule file**:
```bash
mkdir -p deploy/argocd/apps/<app-name>/kustomize
touch deploy/argocd/apps/<app-name>/kustomize/prometheus.yaml
touch deploy/argocd/apps/<app-name>/kustomize/kustomization.yaml
```

2. **Define alerts based on application type**:

**For applications WITH native Prometheus metrics**:
```yaml
# apps/<app-name>/kustomize/prometheus.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: <app-name>-prometheus-rules
  namespace: <app-namespace>
  labels:
    prometheus: <app-name>
    role: alert-rules
spec:
  groups:
  - name: <app-name>.rules
    interval: 30s
    rules:
    # CRITICAL: Component availability
    - alert: <AppName>Down
      expr: absent(up{job="<app-name>"}) == 1
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: <App> is unavailable
        description: <App> has been down for 5 minutes

    # HIGH: Performance degradation
    - alert: <AppName>HighLatency
      expr: histogram_quantile(0.99, rate(<metric>_bucket[5m])) > <threshold>
      for: 10m
      labels:
        severity: high

    # WARNING: Resource saturation
    - alert: <AppName>HighMemory
      expr: <memory_metric> > <threshold>
      for: 10m
      labels:
        severity: warning
```

**For applications WITHOUT native metrics** (use kube-state-metrics):
```yaml
# apps/<app-name>/kustomize/prometheus.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: <app-name>-prometheus-rules
  namespace: <app-namespace>
spec:
  groups:
  - name: <app-name>.rules
    interval: 30s
    rules:
    - alert: <AppName>PodDown
      expr: |
        kube_deployment_status_replicas_available{
          deployment="<app-name>",
          namespace="<namespace>"
        } == 0
      for: 5m
      labels:
        severity: critical

    - alert: <AppName>PodCrashLooping
      expr: |
        rate(kube_pod_container_status_restarts_total{
          pod=~"<app-name>.*",
          namespace="<namespace>"
        }[15m]) > 0
      for: 10m
      labels:
        severity: critical
```

3. **Create kustomization.yaml**:
```yaml
# apps/<app-name>/kustomize/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - prometheus.yaml
```

4. **Update ApplicationSet to include monitoring source**:
```yaml
# apps/<app-name>/applicationset.yaml
templatePatch: |
  spec:
    {{- if .features.monitoring.enabled }}
    sources:
      # Source 1: Main application resources
      - repoURL: https://github.com/gigi206/k8s
        targetRevision: '{{ .git.revision }}'
        path: deploy/argocd/apps/<app-name>/resources

      # Source 2: PrometheusRules (with release label)
      - repoURL: https://github.com/gigi206/k8s
        targetRevision: '{{ .git.revision }}'
        path: deploy/argocd/apps/<app-name>/kustomize
        kustomize:
          commonLabels:
            release: '{{ .features.monitoring.release }}'
    {{- end }}
```

### Alert Severity Guidelines

Use these severity levels consistently:

- **critical**: Component down, data loss, security breach
  - Examples: Pod unavailable, database down, certificate expired
  - Action: Immediate response required (pager alert)

- **high**: Performance degradation, partial failure
  - Examples: High latency (>5s), replica down, disk >90%
  - Action: Investigate within 1 hour

- **warning**: Approaching limits, minor issues
  - Examples: Disk >70%, high connection rate, sync errors
  - Action: Investigate during business hours

- **medium**: Informational, trends
  - Examples: Config reload, backup completed
  - Action: Track for patterns

### Mandatory Alert Categories per Application Type

**Infrastructure components** (LoadBalancer, Ingress, Storage):
- ✅ Availability alerts (component down, pods not ready)
- ✅ Performance alerts (high latency, throughput)
- ✅ Resource alerts (CPU/memory/disk saturation)
- ✅ Error rate alerts (5xx errors, failures)

**Data layer** (Databases, Storage):
- ✅ Availability + Performance + Resource
- ✅ Data integrity alerts (replication lag, corruption)
- ✅ Capacity alerts (disk space, connection pools)

**Networking** (CNI, DNS, Proxy):
- ✅ Availability + Performance
- ✅ Connectivity alerts (node-to-node, endpoints)
- ✅ Packet loss/drops

**Observability** (Monitoring, Logging):
- ✅ Availability
- ✅ Data loss alerts (events lost, scrape failures)
- ✅ Self-monitoring (Prometheus disk full)

### Current Alert Coverage

| Application | Alerts | Status |
|-------------|--------|--------|
| cilium-monitoring | 10 | ✅ Complete |
| longhorn | 9 | ✅ Complete |
| istio | 5 | ✅ Complete |
| argocd | 13 | ✅ Complete |
| metallb | 8 | ✅ Complete |
| external-dns | 7 | ✅ Complete |
| cert-manager | 6 | ✅ Complete |
| kube-vip | 3 | ✅ Complete |
| csi-external-snapshotter | 3 | ✅ Complete |
| prometheus-stack | 57+ | ✅ Complete |
| gateway-api-controller | 2 | ✅ Complete |
| jaeger | 9 | ✅ Complete |

**Target**: Maintain >90% application coverage

### Testing Alerts

After creating alerts, verify they work:

```bash
# 1. Check PrometheusRule is loaded
kubectl get prometheusrules -A

# 2. Verify in Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Browse to http://localhost:9090/rules

# 3. Test alert triggers (optional, in dev only)
# Scale down app to trigger alert
kubectl scale deployment <app-name> --replicas=0 -n <namespace>

# 4. Check alert fires in Prometheus/Grafana
# Wait for alert "for" duration + evaluation interval
```

### Resources for Creating Alerts

- **Metrics discovery**: `kubectl port-forward -n monitoring prometheus-xyz 9090:9090` → http://localhost:9090/graph
- **PromQL help**: https://prometheus.io/docs/prometheus/latest/querying/basics/
- **Alert examples**: Check existing apps in `apps/*/kustomize/prometheus.yaml`
- **Metric naming**: https://prometheus.io/docs/practices/naming/

## Environment Differences

- **dev**: RKE2 via Vagrant, auto-sync enabled, 1 replica, 11 apps, ~3GB RAM usage
- **prod**: HA replicas (3+), manual sync, production-grade storage/monitoring/security

## Important Notes

### ArgoCD UI Access

ArgoCD is accessible via ingress at https://argocd.k8s.lan in dev environment.

Alternatively, use port-forward:
```bash
kubectl port-forward -n argo-cd svc/argocd-server 8080:443

# Get admin password
kubectl -n argo-cd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### Kube-VIP Configuration

The `deploy-applicationsets.sh` script automatically:
1. Waits for Kube-VIP DaemonSet to deploy
2. Retrieves the VIP address from DaemonSet env vars
3. Updates kubeconfig to use VIP instead of node IP
4. Creates a backup of the old kubeconfig

This ensures HA access to the Kubernetes API.

### Storage Class Timing

Prometheus-Stack is in Wave 75 (not 70) to prevent timing issues where Prometheus tries to create PVCs before Longhorn's StorageClass is fully ready. The ApplicationSet has enhanced retry policy:
- 5 retry attempts (was 3)
- 10s initial backoff (was 5s)
- 5m max retry duration (was 3m)

## Troubleshooting

### Applications Not Syncing

1. Check if ApplicationSet exists:
```bash
kubectl get applicationset -n argo-cd
```

2. Check if Application was generated:
```bash
kubectl get application -n argo-cd <app-name> -o yaml
```

3. Check for sync errors:
```bash
kubectl get application -n argo-cd <app-name> \
  -o jsonpath='{.status.conditions[?(@.type=="SyncError")].message}'
```

4. Force refresh from Git:
```bash
kubectl -n argo-cd patch application <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Configuration Changes Not Applied

**Issue**: You pushed changes to Git but ArgoCD doesn't see them.

**Solution**: ArgoCD reads from GitHub, not your local files. Make sure to:
```bash
git push origin <branch>  # Push your commits!
```

Then force refresh:
```bash
kubectl -n argo-cd patch application <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### StorageClass Not Found

**Issue**: "storage class 'longhorn' does not exist"

**Cause**: Timing issue - app tried to create PVC before Longhorn was ready.

**Solution**: Delete and recreate the resource:
```bash
# For Prometheus example:
kubectl delete prometheus -n monitoring prometheus-stack-kube-prom-prometheus
kubectl -n argo-cd patch application prometheus-stack --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Cluster Access Issues

```bash
# Verify cluster is running
cd vagrant && K8S_ENV=dev vagrant status

# Get fresh kubeconfig from master node
cd vagrant && K8S_ENV=dev vagrant ssh k8s-dev-m1 \
  -c "sudo cat /etc/rancher/rke2/rke2.yaml" | \
  sed "s/127.0.0.1/192.168.121.11/g" > .kube/config-dev
```

## Deployment Script

The `deploy/argocd/deploy-applicationsets.sh` script provides:
- Environment auto-detection (dev/prod/local)
- ApplicationSet deployment with progress tracking
- Application health monitoring
- Kube-VIP VIP detection and kubeconfig update
- Comprehensive final status report with ingress URLs
- Configurable timeouts via environment variables

Run with verbose mode:
```bash
cd deploy/argocd
bash deploy-applicationsets.sh -v
```

## File Structure (Current)

```
sops/                                       # AGE private keys for SOPS decryption (⚠️ demo only - plaintext in repo)
├── age-dev.key                             # Dev environment key
└── age-prod.key                            # Prod environment key

deploy/argocd/
├── .sops.yaml                              # SOPS config (public keys, encryption rules)
├── deploy-applicationsets.sh              # Deployment script (hardcoded list of apps)
├── config/
│   └── config.yaml                        # Global configuration (shared by all apps)
├── apps/
│   ├── argocd/
│   │   ├── applicationset.yaml           # Wave 50
│   │   ├── config/
│   │   │   ├── dev.yaml
│   │   │   └── prod.yaml
│   │   └── kustomize/
│   │       ├── kustomization.yaml
│   │       ├── prometheus.yaml
│   │       └── grafana-dashboard.yaml
│   ├── metallb/
│   │   ├── applicationset.yaml           # Wave 10
│   │   ├── config/
│   │   │   ├── dev.yaml
│   │   │   └── prod.yaml
│   │   └── resources/
│   │       ├── ipaddresspool.yaml
│   │       └── l2advertisement.yaml
│   ├── kube-vip/
│   │   ├── applicationset.yaml           # Wave 15
│   │   ├── config/
│   │   │   ├── dev.yaml
│   │   │   └── prod.yaml
│   │   ├── resources/
│   │   │   ├── rbac.yaml
│   │   │   └── daemonset.yaml
│   │   └── README.md
│   ├── cert-manager/
│   ├── external-dns/
│   ├── gateway-api-controller/
│   ├── ingress-nginx/
│   ├── nginx-gateway-fabric/             # NOT deployed by default
│   │   ├── applicationset.yaml           # Wave 41 (manual deployment)
│   │   ├── config/
│   │   │   ├── dev.yaml
│   │   │   └── prod.yaml
│   │   └── README.md
│   ├── csi-external-snapshotter/
│   ├── longhorn/
│   ├── prometheus-stack/
│   │   ├── applicationset.yaml           # Wave 75
│   │   ├── config/
│   │   │   ├── dev.yaml
│   │   │   └── prod.yaml
│   │   ├── kustomize/
│   │   │   ├── kustomization.yaml
│   │   │   └── prometheus.yaml
│   │   └── secrets/                       # Encrypted secrets (KSOPS)
│   │       ├── kustomization.yaml
│   │       ├── ksops-generator.yaml
│   │       ├── secret-dev.yaml           # Grafana credentials (encrypted)
│   │       └── secret-prod.yaml
│   ├── cilium-monitoring/
│   │   ├── applicationset.yaml           # Wave 76
│   │   ├── config/
│   │   │   ├── dev.yaml
│   │   │   └── prod.yaml
│   │   ├── kustomize/
│   │   │   ├── kustomization.yaml
│   │   │   └── servicemonitors.yaml
│   │   └── README.md
│   └── jaeger/
│       ├── applicationset.yaml           # Wave 77
│       ├── config/
│       │   ├── dev.yaml                  # All-in-one mode, Badger storage
│       │   └── prod.yaml                 # Collector+Query, Elasticsearch
│       ├── resources/
│       │   ├── namespace.yaml
│       │   └── waypoints.yaml            # Istio Waypoint Gateway for L7 tracing
│       ├── httproute/
│       │   └── httproute.yaml
│       └── kustomize/
│           ├── kustomization.yaml
│           └── prometheus.yaml           # Jaeger alerts
└── deploy-applicationsets.sh              # Deployment automation script
mise.toml                                  # Tool version management (yq)
```

## Key Advantages of Current Architecture

✅ **Clear Organization**: Each app in its own directory with config and resources
✅ **Per-App Configuration**: No monolithic config file, easier to review changes
✅ **Pure GitOps**: Everything in Git, no external state
✅ **Merge Generator**: Combines global + app-specific config elegantly
✅ **Automatic Discovery**: Bootstrap uses directory generator to find all apps
✅ **Native Go Templates**: Powerful conditional logic and variable substitution
✅ **No Manual Apply**: Push to Git → ArgoCD deploys automatically

## Migration from Previous Architecture

This project was reorganized to use per-application directories:
- **Before**: `argocd/applicationsets/10-metallb.yaml`, `argocd/config/environments/dev.yaml`
- **After**: `deploy/argocd/apps/metallb/applicationset.yaml`, `deploy/argocd/apps/metallb/config/dev.yaml`

Benefits:
- Easier to navigate and understand
- Config changes are localized to one app directory
- Git history is clearer (changes to one app don't affect others)
- Scales better as more apps are added
