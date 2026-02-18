# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GitOps infrastructure project managing Kubernetes applications via ArgoCD ApplicationSet pattern. Supports multiple environments (dev/prod) with centralized configuration, Go templating, and per-application overrides.

## Prerequisites

mise, yq, kubectl, helm, kustomize, argocd, yamllint, vagrant (dev environment).

## Key Architecture Concepts

### ApplicationSet Pattern

- **One ApplicationSet per application** in `deploy/argocd/apps/<app-name>/applicationset.yaml`
- **Go templating** with conditional logic based on `config/config.yaml` flags
- **Per-app config** in `deploy/argocd/apps/<app-name>/config/{env}.yaml`
- **Git Merge Generator** combines global + app-specific config

### Configuration Hierarchy

1. `deploy/argocd/config/config.yaml` (global defaults, feature flags)
2. `deploy/argocd/apps/<app-name>/config/dev.yaml` or `prod.yaml`
3. `deploy/argocd/apps/<app-name>/applicationset.yaml`
4. `deploy/argocd/apps/<app-name>/resources/` and `kustomize/`

### Directory Structure

```
deploy/argocd/
├── config/config.yaml              # Global configuration
├── deploy-applicationsets.sh       # Deployment script
└── apps/<app-name>/
    ├── applicationset.yaml         # ApplicationSet definition
    ├── config/{dev,prod}.yaml      # Environment config + chart version
    ├── resources/                  # Raw YAML (NO kustomization.yaml!)
    ├── kustomize/                  # Overlays with transformations
    │   ├── monitoring/             # ServiceMonitors, PrometheusRules, dashboards
    │   ├── httproute/              # HTTPRoute (Gateway API)
    │   ├── apisix/                 # ApisixRoute/ApisixUpstream
    │   ├── httproute-oauth2-envoy-gateway/  # HTTPRoute + SecurityPolicy OIDC (Envoy Gateway)
    │   ├── oauth2-authz/           # AuthorizationPolicy
    │   ├── sso/                    # ExternalSecrets, Keycloak clients
    │   └── gateway/                # Gateway API resources
    ├── audit-rules.yaml            # Optional: app-specific audit policy rules
    └── secrets/{dev,prod}/         # SOPS-encrypted secrets
```

## Critical Rules

### resources/ vs kustomize/ Convention

| Directory | Usage | Transformations |
|-----------|-------|-----------------|
| `resources/` | Raw YAML deployed as-is | **NONE** - No kustomization.yaml allowed |
| `kustomize/<name>/` | Overlays requiring processing | `patches`, `commonLabels`, `images`, etc. |

In ApplicationSets, `resources/` uses `directory.include`, `kustomize/` uses `kustomize:` block.

### Go Template Variable Limitations

**CRITICAL**: Go templates (`{{ .variable }}`) **ONLY work in ApplicationSet definitions**, NOT in manifest files (`resources/`, `kustomize/*/`, Helm values).

**Solution**: Use Kustomize replacements, Helm templating, or hardcoded values in manifests.

### Feature Flag Conditions

Always use conditions based on `config/config.yaml` to enable optional features:

| Condition | Usage |
|-----------|-------|
| `{{- if .features.monitoring.enabled }}` | kustomize/monitoring/, ServiceMonitor params |
| `{{- if .features.gatewayAPI.enabled }}` | Gateway API routing (parent condition) |
| `{{- if .features.gatewayAPI.httpRoute.enabled }}` | kustomize/httproute/ |
| `{{- if .features.oauth2Proxy.enabled }}` | kustomize/oauth2-authz/ |
| `{{- if .features.networkPolicy.egressPolicy.enabled }}` | {cilium,calico}-egress-policy.yaml |
| `{{- if .features.networkPolicy.ingressPolicy.enabled }}` | {cilium,calico}-host-ingress-policy.yaml |
| `{{- if .features.networkPolicy.defaultDenyPodIngress.enabled }}` | {cilium,calico}-ingress-policy.yaml |
| `{{- if .features.s3.enabled }}` | S3 object storage |
| `{{- if .features.sso.enabled }}` | secrets/, ExternalSecret, KeycloakClient |
| `{{- if .features.tracing.enabled }}` | tracing config |
| `{{- if .features.serviceMesh.enabled }}` | service mesh integration |
| `{{- if .features.ingress.enabled }}` | Ingress config |
| `{{- if .features.registry.enabled }}` | Container registry (harbor) |
| `{{- if .features.certManager.enabled }}` | TLS annotations |
| `{{- if eq .cluster.distribution "k3d" }}` | K3d-specific resources (e.g., webhook policies with host+remote-node) |
| `{{- if .features.containerRuntime.enabled }}` | container runtime sandbox (kata, gvisor) |
| `{{- if .syncPolicy.automated.enabled }}` | automated sync block |

**Combined conditions**: `{{- if and .features.sso.enabled (eq .features.sso.provider "keycloak") }}`

**CNI branching**: nest `{{- if eq .cni.primary "cilium" }}` / `{{- else if eq .cni.primary "calico" }}` inside feature conditions.

**Gateway API routing**: when `gatewayAPI.enabled`, use `httpRoute.enabled` for HTTPRoute, else check `controller.provider` for native CRDs (e.g., ApisixRoute).

### Sync Waves

Sync waves only work **WITHIN a single Application**, not between Applications.
- Wave `-1`: CRDs, Namespaces | Wave `0`: Default | Wave `1`: CRs depending on CRDs

**ExternalSecrets**: NEVER use PreSync hooks or sync-wave. Let ArgoCD retry automatically.

### TLS Certificate Validation

**NEVER** disable TLS verification (`--insecure`, `verify: false`, `skip_tls_verify`). Use the cluster CA via `selfsigned-cluster-issuer-ca` Secret synced with ClusterSecretStore.

## Working with Configuration

### Modifying an Application

1. Edit `deploy/argocd/apps/<app-name>/config/dev.yaml`
2. Commit and push to Git
3. ArgoCD auto-syncs (dev) or manually sync (prod)

### Adding a New Application

1. `mkdir -p deploy/argocd/apps/my-app/{config,resources}`
2. Copy ApplicationSet from existing app as template
3. Create `config/dev.yaml` and `config/prod.yaml`
4. Add to `deploy-applicationsets.sh` if needed
5. Add Prometheus alerts in `kustomize/monitoring/`
6. Add `audit-rules.yaml` if the app has security-relevant CRDs (see existing kyverno/cert-manager examples)
7. Add Renovate custom manager in `renovate.json`
8. Create `README.md` in the app directory

### Helm Chart Analysis (Mandatory for New Apps)

```bash
helm repo add <repo-name> <repo-url> && helm repo update
helm pull <repo-name>/<chart-name> --untar --untardir /tmp/claude
# Explore: values.yaml, Chart.yaml (dependencies), templates/, crds/
helm template my-release <repo-name>/<chart-name> > /tmp/claude/rendered.yaml
```

### Documentation Updates (Mandatory)

- Update `apps/<app-name>/README.md` when modifying an app
- Create `apps/<app-name>/README.md` when adding a new app

## Secrets Management (SOPS/KSOPS)

SOPS with AGE encryption. Structure: `kustomization.yaml` → `ksops-generator.yaml` → `secret.yaml` (encrypted).

```bash
cd deploy/argocd
sops encrypt --in-place apps/<app>/secrets/dev/secret.yaml  # Encrypt
sops apps/<app>/secrets/dev/secret.yaml                      # Edit
sops decrypt apps/<app>/secrets/dev/secret.yaml              # View
```

## Key Patterns (Quick Reference)

- **ServiceMonitor discovery**: must have label `release: prometheus-stack` (use `commonLabels` in kustomization.yaml)
- **Grafana dashboards**: ConfigMaps with `grafana_dashboard: "1"` label
- **PVC protection**: `argocd.argoproj.io/sync-options: Prune=false`
- **ArgoCD finalizers**: add `resources-finalizer.argocd.argoproj.io` to delete resources on app deletion
- **ignoreDifferences**: use for externally managed fields (e.g., `/spec/replicas` with HPA)
- **Version management**: chart version in `config/dev.yaml`, referenced as `{{ .appname.version }}`
- **Multi-source apps**: Helm source with `$values` ref + Git source with `ref: values` + Kustomize paths
- **Network policies**: CNI-specific files (`cilium-*-policy.yaml` / `calico-*-policy.yaml`). See `apps/cilium/README.md`
- **Cluster distribution**: `cluster.distribution: "rke2" | "k3d" | "k3s" | "kubeadm"` in `config/config.yaml`. Controls distribution-specific resources (e.g., K3d webhook policies)
- **CNI selection**: `cni.primary: "cilium" | "calico"` in `config/config.yaml`. See `apps/cilium/README.md`, `apps/calico/README.md` (if exists)
- **LoadBalancer providers**: metallb, cilium, loxilb, kube-vip, klipper. See `deploy-applicationsets.sh`
- **PostSync hooks**: use `hook-delete-policy: BeforeHookCreation,HookSucceeded` for idempotent Jobs (allows re-sync after failure)
- **Helm admin secrets**: use `existingSecret*` pattern + SOPS instead of hardcoding passwords in values
- **Bootstrap features** (Cilium encryption, mutual auth, audit logging): applied via `install_master.sh`, NOT ArgoCD
- **Audit policy fragments**: apps can declare `audit-rules.yaml` with K8s audit rules (bare YAML list items, no `rules:` wrapper). Assembled at bootstrap by `install_master.sh` into `/etc/rancher/rke2/audit-policy.yaml` from `deploy/argocd/audit-policy-base.yaml` + all `apps/*/audit-rules.yaml`. Rules for uninstalled CRDs are harmless. Requires cluster rebuild to pick up new fragments

## Common Commands

```bash
make dev-full                    # Create Vagrant cluster + install everything
make vagrant-dev-up              # Create cluster only
make argocd-install-dev          # Install ArgoCD + deploy ApplicationSets
make vagrant-dev-ssh             # SSH to master node
kubectl get applications -n argo-cd
kubectl get applicationsets -n argo-cd
```

## Environment Differences

- **dev**: RKE2 via Vagrant, auto-sync enabled, 1 replica
- **prod**: HA replicas (3+), manual sync, production-grade settings

## Problem Resolution Strategy

**Priority**: Context7 MCP docs → Official docs (WebFetch) → GitHub issues → Web search

## Troubleshooting

- **App not syncing**: `kubectl get applicationset -n argo-cd`, force refresh with `argocd.argoproj.io/refresh: hard` annotation
- **Config not applied**: ArgoCD reads from Git, always `git push` then force refresh
- **StorageClass not found**: timing issue, delete resource and let ArgoCD recreate after storage is ready

## App-Specific Documentation

Each app has detailed docs: `deploy/argocd/apps/<app-name>/README.md`
