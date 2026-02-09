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
| `{{- if .features.gatewayAPI.enabled }}` | Gateway API routing (parent condition) |
| `{{- if .features.gatewayAPI.httpRoute.enabled }}` | kustomize/httproute/ (Gateway API standard) |
| `{{- if .features.oauth2Proxy.enabled }}` | kustomize/oauth2-authz/ |
| `{{- if .features.networkPolicy.egressPolicy.enabled }}` | resources/cilium-egress-policy.yaml or calico-egress-policy.yaml |
| `{{- if .features.networkPolicy.ingressPolicy.enabled }}` | resources/cilium-host-ingress-policy.yaml or calico-host-ingress-policy.yaml |
| `{{- if .features.networkPolicy.defaultDenyPodIngress.enabled }}` | resources/cilium-ingress-policy.yaml or calico-ingress-policy.yaml |
| `{{- if .features.cilium.encryption.enabled }}` | WireGuard/IPsec encryption (Cilium-only, bootstrap) |
| `{{- if .features.cilium.mutualAuth.enabled }}` | SPIFFE/SPIRE mutual authentication (Cilium-only, bootstrap) |
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

**CNI-aware network policy conditions** (use nested `if` for CNI branching):
```yaml
{{- if .features.networkPolicy.egressPolicy.enabled }}
  {{- if eq .cni.primary "cilium" }}
  - path: deploy/argocd/apps/<app>/resources
    directory:
      include: "cilium-egress-policy.yaml"
  {{- else if eq .cni.primary "calico" }}
  - path: deploy/argocd/apps/<app>/resources
    directory:
      include: "calico-egress-policy.yaml"
  {{- end }}
{{- end }}
```

**Gateway API Routing Conditional Logic**:
```yaml
{{- if .features.gatewayAPI.enabled }}
  {{- if .features.gatewayAPI.httpRoute.enabled }}
  # HTTPRoute (Gateway API standard) - works with all providers
  - path: deploy/argocd/apps/<app>/kustomize/httproute
  {{- else if eq .features.gatewayAPI.controller.provider "apisix" }}
  # ApisixRoute (native CRDs) - when HTTPRoute disabled and provider is APISIX
  - path: deploy/argocd/apps/<app>/kustomize/apisix
  {{- end }}
{{- end }}
```

| `gatewayAPI.enabled` | `httpRoute.enabled` | `provider` | Result |
|---------------------|---------------------|------------|--------|
| `false` | - | - | No routing |
| `true` | `true` | any | HTTPRoute |
| `true` | `false` | `apisix` | ApisixRoute |
| `true` | `false` | other | No routing |

**APISIX CRDs** support native HTTPS backend via `ApisixUpstream` with `scheme: https` (no workaround needed).

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
    ├── resources/                  # Raw YAML manifests (NO kustomization.yaml!)
    │   ├── cilium-egress-policy.yaml  # CiliumNetworkPolicy (raw)
    │   └── namespace.yaml             # Namespace (raw)
    ├── kustomize/                  # Kustomize overlays (with transformations)
    │   ├── monitoring/            # PrometheusRules, ServiceMonitors, dashboards
    │   ├── httproute/             # HTTPRoute (conditional: gatewayAPI.httpRoute.enabled)
    │   ├── apisix/                # ApisixRoute/ApisixUpstream (conditional: provider=apisix)
    │   ├── oauth2-authz/          # AuthorizationPolicy (conditional: oauth2Proxy.enabled)
    │   ├── sso/                   # ExternalSecrets, Keycloak clients (conditional: sso.enabled)
    │   ├── gateway/               # Gateway API resources (istio-gateway)
    │   └── custom-resources/      # App-specific CRs (keycloak)
    └── secrets/                    # SOPS-encrypted secrets
        ├── dev/
        └── prod/
```

### resources/ vs kustomize/ Directory Convention

**Criterion**: Does the directory use Kustomize transformations?

| Directory | Usage | Transformations |
|-----------|-------|-----------------|
| `resources/` | Raw YAML files deployed as-is | **NONE** - No kustomization.yaml allowed |
| `kustomize/<name>/` | Overlays requiring processing | `patches`, `commonLabels`, `images`, etc. |

**IMPORTANT**: The `resources/` directory must **NEVER** contain a `kustomization.yaml` file. All files that require Kustomize transformations (images replacement, patches, commonLabels) must be in `kustomize/<name>/`.

**Common kustomize subdirectories**:
- `kustomize/monitoring/` → ServiceMonitors, PrometheusRules (uses `commonLabels: release`)
- `kustomize/httproute/` → HTTPRoute (uses `patches` for domain injection)
- `kustomize/sso/` → ExternalSecrets, Keycloak client Jobs (uses `images`, `patches`)
- `kustomize/gateway/` → Gateway API resources (uses `patches`)
- `kustomize/oauth2-authz/` → AuthorizationPolicy (uses `patches`)

**Examples**:
- `resources/cilium-egress-policy.yaml` → Raw CiliumNetworkPolicy, no transformation needed
- `resources/namespace.yaml` → Raw Namespace, deployed via `directory.include`
- `kustomize/sso/keycloak-client.yaml` → Uses `images:` for curl tag replacement

**In ApplicationSets**, conditional resources from `resources/` use `directory.include`:
```yaml
{{- if .features.cilium.egressPolicy.enabled }}
- path: deploy/argocd/apps/my-app/resources
  directory:
    include: "cilium-egress-policy.yaml"
{{- end }}
```

**Kustomize sources** use the `kustomize:` block:
```yaml
{{- if .features.sso.enabled }}
- path: deploy/argocd/apps/my-app/kustomize/sso
  kustomize:
    images:
      - 'curlimages/curl={{ .images.curl.repository }}:{{ .images.curl.tag }}'
{{- end }}
```

### Sync Waves (Intra-Application Only)

**IMPORTANT**: Sync waves only work for resources **WITHIN a single Application**. They do **NOT** control the order between separate Applications (ArgoCD syncs Applications in parallel).

Use `argocd.argoproj.io/sync-wave` annotation on resources to control deployment order within an Application:
- Wave `-1`: CRDs, Namespaces (deploy first)
- Wave `0`: Default (Secrets, ConfigMaps, Services)
- Wave `1`: Custom Resources that depend on CRDs

**Example** (in keycloak app):
- `KeycloakRealmImport` has `sync-wave: "1"` to deploy after secrets (wave 0)

**IMPORTANT - ExternalSecret Sync Waves**:
- **NEVER use PreSync hooks** for ExternalSecrets. If the external-secrets webhook is not ready, PreSync hooks **block the entire sync** indefinitely.
- **DO NOT use sync-wave** for ExternalSecrets - let ArgoCD sync all resources in parallel and retry failures automatically.
- The `external-secrets` app includes a **PostSync Job** (`webhook-readiness-check`) that verifies the webhook is ready before marking the app as Healthy.

### Feature Flags

Feature flags in `config/config.yaml` control which ApplicationSets are deployed.

Examples:
- `cni.primary` → cilium | calico (CNI selection, default: cilium)
- `features.loadBalancer.provider` → metallb | cilium | loxilb | kube-vip | klipper
- `features.monitoring.enabled` → prometheus-stack
- `features.sso.enabled` + `provider=keycloak` → keycloak

**LoadBalancer Providers**:
| Provider | Description | Static IPs | IP Pool |
|----------|-------------|------------|---------|
| `metallb` | MetalLB (stable, simple setup) | Yes | Yes |
| `cilium` | Cilium LB-IPAM with L2 announcements | Yes | Yes |
| `loxilb` | LoxiLB eBPF-based | Yes | Yes |
| `kube-vip` | kube-vip cloud provider (ConfigMap-based IPAM) | Yes | Yes |
| `klipper` | ServiceLB (RKE2/K3s built-in) | **No** | No (uses node IPs) |

**Notes**:
- When using `klipper`, staticIP annotations are ignored as Klipper uses node IPs directly.
- When using `cilium`, the L2 announcement interface must be in Cilium's `devices` list (see `apps/cilium/README.md`).
- When using `kube-vip`, kube-vip-cloud-provider handles IPAM and kube-vip handles ARP announcements (automatic `svc_enable=true`). **Requires `features.kubeVip.enabled: true`**.
- `features.loadBalancer.provider=cilium` requires `cni.primary=cilium` (LB-IPAM is Cilium-specific).

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

### Helm Chart Analysis

**MANDATORY**: Before configuring a new application, always analyze the Helm chart to understand its structure and available options.

**Step 1 - Download the chart for in-depth analysis**:
```bash
# Add the repo if not already added
helm repo add <repo-name> <repo-url>
helm repo update

# Download and extract the chart locally
helm pull <repo-name>/<chart-name> --untar --untardir /tmp/claude

# Explore the chart structure
ls /tmp/claude/<chart-name>/
cat /tmp/claude/<chart-name>/values.yaml      # Default values
cat /tmp/claude/<chart-name>/Chart.yaml       # Chart metadata & dependencies
ls /tmp/claude/<chart-name>/templates/        # All templates
```

**Step 2 - Render templates to understand generated manifests**:
```bash
# Basic render with default values
helm template my-release <repo-name>/<chart-name> > /tmp/claude/rendered.yaml

# Render with custom values to test configuration
helm template my-release <repo-name>/<chart-name> \
  --namespace my-namespace \
  --set key1=value1 \
  --set key2.nested=value2 \
  -f /tmp/claude/custom-values.yaml \
  > /tmp/claude/rendered.yaml

# Render specific templates only
helm template my-release <repo-name>/<chart-name> \
  --show-only templates/deployment.yaml
```

**Key analysis points**:
- **values.yaml**: Identify all configurable parameters and their defaults
- **templates/**: Understand what Kubernetes resources are created
- **Chart.yaml**: Check dependencies (subcharts) that may need configuration
- **NOTES.txt**: Post-install instructions and access information
- **CRDs**: Check `crds/` directory for Custom Resource Definitions

**Example workflow for a new app**:
```bash
# Download and analyze cert-manager chart
helm repo add jetstack https://charts.jetstack.io
helm pull jetstack/cert-manager --untar --untardir /tmp/claude

# Render with monitoring enabled to see ServiceMonitor
helm template cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set prometheus.servicemonitor.enabled=true \
  > /tmp/claude/cert-manager-rendered.yaml

# Search for specific resources
grep -A 20 "kind: ServiceMonitor" /tmp/claude/cert-manager-rendered.yaml
```

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

### CNI Selection (`cni.primary`)

The CNI is selectable via `cni.primary: "cilium" | "calico"` in `config/config.yaml`. Both use eBPF dataplane with kube-proxy replacement.

| CNI | Dataplane | Policy API | Host Firewall | Encryption | Mutual Auth |
|-----|-----------|-----------|---------------|------------|-------------|
| **Cilium** | eBPF | `cilium.io/v2` (CiliumNetworkPolicy) | CiliumClusterwideNetworkPolicy + nodeSelector | WireGuard/IPsec | SPIFFE/SPIRE |
| **Calico** | eBPF | `projectcalico.org/v3` (NetworkPolicy/GlobalNetworkPolicy) | GlobalNetworkPolicy + HostEndpoints | Not supported | Not supported |

**Bootstrap**: `install_master.sh` dispatches to `configure_cilium.sh` or `configure_calico.sh` based on `CNI_PRIMARY`.

### Network Policy Pattern

**Configuration flags** (`config/config.yaml`) - CNI-agnostic, apply to both Cilium and Calico:
- `features.networkPolicy.egressPolicy.enabled` → Blocks pod → external traffic. Apps needing external access require `{cilium,calico}-egress-policy.yaml`.
- `features.networkPolicy.ingressPolicy.enabled` → Blocks external → node traffic. LoadBalancer apps require `{cilium,calico}-host-ingress-policy.yaml`.
- `features.networkPolicy.defaultDenyPodIngress.enabled` → Blocks pod → pod traffic (Zero Trust). All apps require `{cilium,calico}-ingress-policy.yaml` to receive traffic.

**Per-CNI policy file naming**:
| Type | Cilium file | Calico file |
|------|------------|-------------|
| Egress | `cilium-egress-policy.yaml` | `calico-egress-policy.yaml` |
| Pod ingress | `cilium-ingress-policy.yaml` | `calico-ingress-policy.yaml` |
| Host ingress | `cilium-host-ingress-policy.yaml` | `calico-host-ingress-policy.yaml` |
| Provider ingress | `cilium-ingress-policy-{provider}.yaml` | `calico-ingress-policy-{provider}.yaml` |

**Cluster-wide default-deny policies**:
- Cilium: `apps/cilium/resources/default-deny-*.yaml` (CiliumClusterwideNetworkPolicy)
- Calico: `apps/calico/resources/default-deny-*.yaml` (GlobalNetworkPolicy)

**Host firewall**:
- Cilium: `nodeSelector` on CiliumClusterwideNetworkPolicy
- Calico: `selector: has(kubernetes-host)` on GlobalNetworkPolicy (requires HostEndpoint auto-creation)

All host policies use node labels (`node-role.kubernetes.io/ingress` or `node-role.kubernetes.io/dns`):
```bash
kubectl label node <worker> node-role.kubernetes.io/ingress=""
```

**Troubleshooting** (Cilium with Hubble):
```bash
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --last 50
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --to-namespace <ns>
```
See `apps/cilium/README.md` for detailed troubleshooting.

**Cilium-only features** (encryption & mutual authentication, bootstrap-level via `configure_cilium.sh`):
- `features.cilium.encryption.enabled` → WireGuard/IPsec transparent encryption
  - `type`: `wireguard` (recommended, GA) or `ipsec` (FIPS-compliant, GA)
  - `nodeEncryption`: encrypt node-to-node traffic (not just pod-to-pod)
  - `strictMode.enabled`: drop unencrypted traffic (prevents leaks)
- `features.cilium.mutualAuth.enabled` → SPIFFE/SPIRE mutual authentication (Beta)
  - Sidecarless: eBPF + per-node SPIRE agent (no Envoy sidecar)

These are applied at RKE2 bootstrap via `install_master.sh` → `configure_cilium.sh` → HelmChartConfig, **not** through ArgoCD ApplicationSet.

**Calico-specific settings** (`features.calico.*`):
- `features.calico.monitoring.enabled` → ServiceMonitors + PrometheusRules + dashboards
- `features.calico.dataplane` → `bpf` (eBPF, default) or `iptables`
- `features.calico.encapsulation` → `VXLAN` (default), `IPIP`, or `None` (BGP)
- `features.calico.bgp.enabled` → BGP peering (default: false)

### HTTPRoute Structure

HTTPRoutes reference a Gateway (`parentRefs` → `default-gateway` in `istio-system`) with `hostnames` and `backendRefs` to services.

### Multi-Source Application Pattern

Combine Helm chart + Kustomize overlays using multiple `sources`: Helm source with `$values` reference, Git source with `ref: values`, and additional Kustomize paths.

### PVC Protection

Prevent PVC deletion with annotation `argocd.argoproj.io/sync-options: Prune=false` on the resource or globally in `syncPolicy.syncOptions`.

### ArgoCD Finalizers

Add `resources-finalizer.argocd.argoproj.io` finalizer to delete resources when Application is deleted (without it, resources are orphaned).

## Problem Resolution Strategy

When encountering issues (errors, unexpected behavior, configuration problems), follow this research strategy:

### 1. Check Documentation via MCP Context7

Use the Context7 MCP server to retrieve up-to-date documentation:
```
# First resolve the library ID
mcp__context7__resolve-library-id(libraryName: "argocd", query: "applicationset generator")

# Then query the documentation
mcp__context7__query-docs(libraryId: "/argoproj/argo-cd", query: "how to use git generator")
```

### 2. Consult Official Documentation Online

Use WebFetch or WebSearch to access the official documentation of the relevant tool/library.

### 3. Search GitHub Issues

Search for known issues and solutions in the project's GitHub repository using `gh search issues` or WebSearch.

### 4. Search the Web

For broader searches when the above don't yield results, use WebSearch.

**Priority order**: Context7 docs → Official docs → GitHub issues → Web search

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
