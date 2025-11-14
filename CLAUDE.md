# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitOps infrastructure project that manages Kubernetes applications using ArgoCD with ApplicationSet pattern. The infrastructure supports multiple environments (dev/prod) with centralized configuration, Go templating, and per-application overrides.

## Key Architecture Concepts

### ApplicationSet-Based Application Management

This project uses ArgoCD ApplicationSets to declaratively manage applications:
- **One ApplicationSet per application** in its own directory (`deploy/argocd/apps/<app-name>/applicationset.yaml`)
- **Native Go templating** with conditional logic (`{{ if .features.monitoring.enabled }}`)
- **Per-application configuration** in `deploy/argocd/apps/<app-name>/config/{env}.yaml`
- **Git Merge Generator** reads global + app-specific config and generates Applications
- **Bootstrap Application** creates all ApplicationSets from a directory pattern

### Configuration Hierarchy

1. **Global Config**: `deploy/argocd/config/config.yaml` (shared defaults, common variables)
2. **App-Specific Config**: `deploy/argocd/apps/<app-name>/config/dev.yaml` or `prod.yaml`
3. **ApplicationSet**: `deploy/argocd/apps/<app-name>/applicationset.yaml` (templates the Application)
4. **Resources**: `deploy/argocd/apps/<app-name>/resources/` (K8s manifests, values files, etc.)

The Merge Generator combines global config + app config, then ApplicationSet uses Go templates to generate the final Application.

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
  → Applies ApplicationSets from hardcoded list in script (lines ~267-278)
  → Each ApplicationSet uses Git Merge Generator:
      - Reads deploy/argocd/config/config.yaml (global)
      - Reads deploy/argocd/apps/<app-name>/config/*.yaml (app-specific)
      - Merges configs by "environment" key
  → Go template evaluation (conditions, variables)
  → Generates ArgoCD Application per environment
  → ArgoCD deploys apps via sync waves
```

ApplicationSets are explicitly listed in the script, not auto-discovered. This allows selective deployment.

### Sync Wave Strategy

Applications deploy in order via `argocd.argoproj.io/sync-wave` annotations:
- **Wave 10**: MetalLB (LoadBalancer)
- **Wave 15**: Gateway-API-Controller, Kube-VIP (API HA)
- **Wave 20**: Cert-Manager (TLS certificates)
- **Wave 30**: External-DNS (DNS automation)
- **Wave 40**: Ingress-NGINX (Ingress controller)
- **Wave 50**: ArgoCD (self-management)
- **Wave 55**: CSI-External-Snapshotter (volume snapshots)
- **Wave 60**: Longhorn (distributed storage)
- **Wave 75**: Prometheus-Stack (monitoring) - higher wave to ensure Longhorn StorageClass is ready
- **Wave 76**: Cilium-Monitoring (ServiceMonitors for Cilium/Hubble) - after prometheus-stack

**Note**: Prometheus-Stack is in Wave 75 (not 70) to give Longhorn time to fully initialize the StorageClass before Prometheus tries to create PVCs. Cilium-Monitoring is in Wave 76 to ensure Prometheus CRDs are available.

## Current Applications (Dev Environment)

1. **metallb** - Layer 2 LoadBalancer (192.168.121.220-250)
2. **gateway-api-controller** - Gateway API CRDs
3. **kube-vip** - VIP for Kubernetes API (192.168.121.200)
4. **cert-manager** - Certificate management (self-signed issuer in dev)
5. **external-dns** - DNS automation with CoreDNS
6. **ingress-nginx** - Ingress controller
7. **argocd** - GitOps controller (self-managed)
8. **csi-external-snapshotter** - Snapshot CRDs for Longhorn
9. **longhorn** - Distributed block storage
10. **prometheus-stack** - Prometheus, Grafana, Alertmanager
11. **cilium-monitoring** - ServiceMonitors for Cilium/Hubble metrics

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

# The script deploys ApplicationSets from a hardcoded list (lines ~267-278)
# Each ApplicationSet then generates ArgoCD Applications
```

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
| ingress-nginx | 9 | ✅ Complete |
| argocd | 13 | ✅ Complete |
| metallb | 8 | ✅ Complete |
| external-dns | 7 | ✅ Complete |
| cert-manager | 6 | ✅ Complete |
| kube-vip | 3 | ✅ Complete |
| csi-external-snapshotter | 3 | ✅ Complete |
| prometheus-stack | 57+ | ✅ Complete |
| gateway-api-controller | 0 | ⚠️ No metrics available |

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

ArgoCD is accessible via ingress at https://argocd.gigix in dev environment.

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
deploy/argocd/
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
│   │   └── kustomize/
│   │       ├── kustomization.yaml
│   │       └── prometheus.yaml
│   └── cilium-monitoring/
│       ├── applicationset.yaml           # Wave 76
│       ├── config/
│       │   ├── dev.yaml
│       │   └── prod.yaml
│       ├── kustomize/
│       │   ├── kustomization.yaml
│       │   └── servicemonitors.yaml
│       └── README.md
└── deploy-applicationsets.sh              # Deployment automation script
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
