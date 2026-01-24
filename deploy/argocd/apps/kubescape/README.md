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

## CLI vs Operator

Kubescape has two deployment modes:

| Aspect | Operator (K8s) | CLI (local) |
|--------|----------------|-------------|
| Installation | Helm chart in cluster | Local binary (mise/curl) |
| Scans | Automatic (CronJob) | On-demand |
| Runtime detection | Yes (eBPF node-agent) | No |
| Historique | Yes (storage component) | No |
| Exceptions | Auto-discovery (ConfigMaps) | Via `--exceptions` file |
| CI/CD | No | Yes |
| Resources | Consumes cluster CPU/RAM | None |

Both use the same scan engine, so results are identical.

## CLI Installation

### Via mise (recommended)

The CLI is configured in `mise.toml` at the project root:

```toml
[tools]
"github:kubescape/kubescape" = "latest"
```

```bash
# Install
mise install

# Verify
mise exec -- kubescape version

# Or after shell reload
kubescape version
```

### Via curl

```bash
curl -s https://raw.githubusercontent.com/kubescape/kubescape/master/install.sh | /bin/bash
```

## CLI Usage

### Framework Scans

```bash
# Scan all frameworks
kubescape scan framework allcontrols

# Scan specific frameworks
kubescape scan framework cis-v1.10.0    # CIS Kubernetes Benchmark
kubescape scan framework nsa            # NSA Hardening Guide
kubescape scan framework mitre          # MITRE ATT&CK
kubescape scan framework soc2           # SOC2 compliance
kubescape scan framework armobest       # ARMO best practices
kubescape scan framework devopsbest     # DevOps best practices

# List available frameworks
kubescape list frameworks
```

### Targeted Scans

```bash
# Scan specific namespace
kubescape scan framework nsa --include-namespaces monitoring

# Scan specific workload
kubescape scan workload deployment/my-app -n my-namespace

# Exclude namespaces
kubescape scan framework cis-v1.10.0 --exclude-namespaces kube-system,kube-public
```

### Output Formats

```bash
# JSON output
kubescape scan framework allcontrols --format json --output results.json

# SARIF format (for GitHub/GitLab integration)
kubescape scan framework allcontrols --format sarif --output results.sarif

# HTML report
kubescape scan framework allcontrols --format html --output report.html

# Verbose output with failed resources
kubescape scan framework allcontrols -v
```

### Using Exceptions

```bash
# Scan with exceptions file
kubescape scan framework allcontrols --exceptions exceptions.json

# Generate exceptions template from failed controls
kubescape scan framework allcontrols --format json | jq '.results[].controls[] | select(.status.status == "failed")' > failed-controls.json
```

## Kubescape Exceptions

### Auto-Discovery Pattern

The operator automatically discovers exceptions from ConfigMaps with the label `custom-object: exceptions`. Each privileged application can declare its own exceptions.

### Exception ConfigMap Format

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <app-name>-kubescape-exceptions
  namespace: <app-namespace>
  labels:
    custom-object: exceptions  # Required for auto-discovery
data:
  exceptions.json: |
    [
      {
        "name": "<exception-name>",
        "policyType": "postureExceptionPolicy",
        "actions": ["alertOnly"],
        "resources": [{
          "designatorType": "Attributes",
          "attributes": {
            "namespace": "<namespace>",
            "kind": "DaemonSet",
            "name": "<workload-name>"
          }
        }],
        "posturePolicies": [
          {"controlID": "C-0034"},
          {"controlID": "C-0017"}
        ]
      }
    ]
```

### Common Control IDs for Exceptions

| Control ID | Name | Typical Reason |
|------------|------|----------------|
| C-0034 | Automatic mapping of SA tokens | App needs K8s API access |
| C-0017 | Immutable container filesystem | App needs writable /tmp |
| C-0016 | Allow privilege escalation | CSI drivers, eBPF |
| C-0055 | Linux hardening (seccomp) | Missing seccomp profile |
| C-0057 | Privileged container | Host access required |
| C-0086 | CVE vulnerabilities | Known acceptable CVEs |
| C-0046 | Insecure capabilities | NET_RAW, SYS_ADMIN |

### Applications with Exceptions

These applications have `kubescape-exceptions.yaml` in their `resources/` directory:

| Application | Namespace | Reason |
|-------------|-----------|--------|
| prometheus-stack | monitoring | node-exporter: hostNetwork, hostPID, hostPath |
| rook | rook-ceph | CSI drivers: privileged disk access |
| kubescape | kubescape | node-agent: eBPF kernel access |
| neuvector | neuvector | enforcer: runtime container inspection |
| metallb | metallb-system | speaker: NET_RAW for ARP |
| alloy | alloy | log collector: hostPath /var/log |

### Adding Exceptions to ApplicationSet

In the ApplicationSet, add a conditional source:

```yaml
{{- if .features.kubescape.enabled }}
# Source: Kubescape exceptions for privileged workloads
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/<app-name>/resources
  directory:
    include: "kubescape-exceptions.yaml"
{{- end }}
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
