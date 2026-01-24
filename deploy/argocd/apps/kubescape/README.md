# Kubescape - Kubernetes Security Scanning

Kubescape is a CNCF incubating project providing comprehensive Kubernetes security scanning.

## Overview

| Property | Value |
|----------|-------|
| **Sync Wave** | 78 |
| **Namespace** | `kubescape` |
| **Helm Chart** | [kubescape/kubescape-operator](https://github.com/kubescape/helm-charts) |
| **Version** | 1.30.2 |

## Features

- **Configuration Scanning**: CIS, NSA, MITRE ATT&CK framework compliance checks
- **Vulnerability Scanning**: CVE detection in container images
- **SBOM Generation**: Software Bill of Materials for all workloads
- **Runtime Observability**: eBPF-based runtime behavior monitoring
- **Network Policy Generation**: Automatic network policy suggestions
- **Admission Controller**: Prevent non-compliant workloads deployment
- **Seccomp Profile Generation**: Auto-generate security profiles

## Components

| Component | Type | Description |
|-----------|------|-------------|
| kubescape | Deployment | Configuration scanner |
| operator | Deployment | Orchestrates scanning and manages CRDs |
| kubevuln | Deployment | Vulnerability scanner (Grype-based) |
| storage | Deployment | Aggregated API server for scan results |
| node-agent | DaemonSet | Runtime observability, SBOM generation |
| host-scanner | DaemonSet | Host-level security scanning |

## Configuration

### Enable/Disable

In `config/config.yaml`:

```yaml
features:
  kubescape:
    enabled: true  # Wave 78: Kubernetes security scanning
```

### Capabilities

Configure in `apps/kubescape/config/dev.yaml`:

```yaml
kubescape:
  capabilities:
    # Configuration scanning
    configurationScan: enable     # Misconfiguration detection
    continuousScan: enable        # Continuous posture evaluation
    nodeScan: enable              # Node security scanning

    # Vulnerability scanning
    vulnerabilityScan: enable     # Image CVE scanning
    relevancy: enable             # Runtime relevancy filtering
    nodeSbomGeneration: enable    # SBOM on nodes

    # Runtime features
    runtimeObservability: enable  # Behavior monitoring
    networkPolicyService: enable  # Network policy suggestions
    admissionController: enable   # Admission control
    runtimeDetection: disable     # eBPF threat detection (prod only)
    malwareDetection: disable     # Malware scanning (resource intensive)
```

### Scanning Schedule

```yaml
kubescape:
  scheduler:
    configScan: "0 8 * * *"     # Daily at 8 AM
    vulnScan: "0 0 * * *"       # Daily at midnight
    registryScan: "0 0 * * *"   # Daily at midnight
```

## Viewing Scan Results

### Configuration Scan Results

```bash
# List all workload configuration scans
kubectl get workloadconfigurationscans -A

# View detailed results
kubectl describe workloadconfigurationscan <name> -n <namespace>
```

### Vulnerability Results

```bash
# List vulnerability manifests (per image)
kubectl get vulnerabilitymanifests -A

# View specific CVEs
kubectl describe vulnerabilitymanifest <name> -n kubescape
```

### Application Profiles (Runtime)

```bash
# List runtime profiles
kubectl get applicationprofiles -A

# View network neighborhoods
kubectl get networkneighborhoods -A
```

### SBOM Data

```bash
# List SBOMs
kubectl get sbomsyfts -A
kubectl get sbomsyftfiltereds -A  # Filtered/relevant SBOMs
```

## CLI Usage

Kubescape can also be used as a CLI tool for on-demand scanning:

```bash
# Install CLI
curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash

# Run all framework scans
kubescape scan

# Scan specific framework
kubescape scan framework nsa
kubescape scan framework cis-v1.23-t1.0.1
kubescape scan framework mitre

# Scan specific workload
kubescape scan workload deployment/my-app -n my-namespace

# Scan with JSON output
kubescape scan --format json --output results.json

# List available frameworks
kubescape list frameworks
```

## Monitoring

### Prometheus Metrics

When `capabilities.prometheusExporter: enable`, metrics are exposed:

| Metric | Description |
|--------|-------------|
| `kubescape_scan_*` | Scan statistics and timings |
| `kubescape_controls_*` | Control pass/fail counts |

### ServiceMonitor

The Helm chart creates ServiceMonitors when enabled:
- `kubescape` - Scanner metrics
- `node-agent` - Node agent metrics

### Prometheus Alerts

Key alerts defined in `kustomize/monitoring/prometheusrules.yaml`:

| Alert | Severity | Description |
|-------|----------|-------------|
| KubescapeScannerDown | critical | Scanner deployment unavailable |
| KubescapeOperatorDown | critical | Operator deployment unavailable |
| KubescapeNodeAgentNotRunningOnAllNodes | warning | Missing node coverage |
| KubescapeScanJobFailed | warning | Scheduled scan job failed |

## Network Policies

### Egress Policy

`resources/cilium-egress-policy.yaml` allows:
- Internal namespace communication
- HTTPS (443) to external services:
  - Grype vulnerability database
  - Control framework updates
  - Container registries

### Ingress Policy

`resources/cilium-ingress-policy.yaml` allows:
- Prometheus scraping from monitoring namespace
- Internal component communication
- API server webhook calls

## Troubleshooting

### Scan Not Running

```bash
# Check CronJobs
kubectl get cronjobs -n kubescape

# Check recent jobs
kubectl get jobs -n kubescape --sort-by=.metadata.creationTimestamp

# View job logs
kubectl logs job/kubescape-scheduler-<id> -n kubescape
```

### Node Agent Issues

```bash
# Check DaemonSet status
kubectl get ds node-agent -n kubescape

# Check node agent logs
kubectl logs ds/node-agent -n kubescape

# Verify eBPF support (if runtimeDetection enabled)
kubectl exec -n kubescape ds/node-agent -- ls /sys/fs/bpf
```

### Storage API Issues

```bash
# Check storage deployment
kubectl get deploy storage -n kubescape

# Test aggregated API
kubectl get --raw /apis/spdx.softwarecomposition.kubescape.io/v1beta1
```

### Admission Controller Issues

```bash
# Check webhook configuration
kubectl get validatingwebhookconfiguration kubescape-admission

# Check admission controller logs
kubectl logs -l app=kubescape -n kubescape
```

## Resource Requirements

### Development (Single Node)

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| kubescape | 100m | 256Mi |
| operator | 25m | 64Mi |
| kubevuln | 150m | 512Mi |
| storage | 50m | 256Mi |
| node-agent | 50m/node | 128Mi/node |

### Production (Multi-Node)

| Component | CPU Request | Memory Request |
|-----------|-------------|----------------|
| kubescape | 250m | 400Mi |
| operator | 50m | 100Mi |
| kubevuln | 300m | 1Gi |
| storage | 100m | 400Mi |
| node-agent | 100m/node | 180Mi/node |

## External Resources

- [Kubescape Documentation](https://kubescape.io/docs/)
- [Helm Charts Repository](https://github.com/kubescape/helm-charts)
- [Kubescape GitHub](https://github.com/kubescape/kubescape)
- [CNCF Landscape](https://landscape.cncf.io/?item=provisioning--security-compliance--kubescape)
