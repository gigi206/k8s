# NeuVector - Container Security

NeuVector provides full lifecycle container security including vulnerability scanning, runtime protection, and compliance.

## Overview

- **Wave**: 82
- **Namespace**: `neuvector`
- **Helm Chart**: [neuvector/core](https://neuvector.github.io/neuvector-helm/)
- **UI Access**: `https://neuvector.<domain>` (via HTTPRoute)

## Features

- Runtime container protection
- Network segmentation and policies
- Vulnerability scanning
- Compliance reporting (PCI, GDPR, HIPAA)
- DLP (Data Loss Prevention)
- WAF capabilities

## Components

- **Controller**: Brain of NeuVector, policy management
- **Enforcer**: DaemonSet for runtime protection
- **Scanner**: Vulnerability scanning
- **Manager**: Web UI

## Authentication

### OIDC with Keycloak

NeuVector integrates with Keycloak for SSO:

```yaml
features:
  sso:
    enabled: true
    provider: keycloak
```

The ApplicationSet automatically:
1. Creates a Keycloak client via Job
2. Syncs CA certificate via ExternalSecret
3. Patches the controller to trust the CA

### CA Certificate Injection

A PostSync Job (`controller-ca-patch-job.yaml`) patches the controller deployment to mount the cluster CA certificate for OIDC TLS verification.

## Monitoring

### Prometheus Exporter

The Prometheus exporter collects metrics from NeuVector.

#### Enforcer Stats (Performance Impact)

By default, enforcer CPU/Memory metrics are **disabled** for performance reasons. Enable only if needed:

```yaml
# config/dev.yaml
neuvector:
  exporter:
    enforcerStats:
      enabled: true  # WARNING: impacts performance
```

When enabled, the exporter exposes `nv_enforcer_cpu` and `nv_enforcer_memory` metrics for the Grafana dashboard.

### Grafana Dashboard

An official NeuVector dashboard is auto-imported into Grafana (folder: NeuVector). It displays:
- System summary (hosts, controllers, enforcers, pods)
- Admission control stats
- CVEDB version and create time
- CPU/Memory usage (requires `enforcerStats.enabled: true`)
- Service and image vulnerabilities
- Security events log

### Prometheus Alerts

14 alertes sont configurées pour NeuVector :

**Controller**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| NeuVectorControllerDown | critical | Controller indisponible (5m) |
| NeuVectorControllerHighMemory | warning | Mémoire > 90% |

**Enforcer**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| NeuVectorEnforcerDown | warning | Enforcers indisponibles (10m) |
| NeuVectorEnforcerNotRunningOnAllNodes | warning | Nodes sans enforcer (15m) |

**Scanner & Manager**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| NeuVectorScannerDown | warning | Scanner indisponible (10m) |
| NeuVectorScannerDegraded | warning | Scanner dégradé (15m) |
| NeuVectorManagerDown | warning | Manager (UI) indisponible (5m) |

**Pods**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| NeuVectorPodCrashLooping | warning | Pod en restart loop (10m) |
| NeuVectorPodNotReady | warning | Pod non ready (10m) |

**Security Events**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| NeuVectorHighCVECount | warning | > 100 CVEs HIGH détectées |
| NeuVectorCriticalCVEDetected | critical | Nouvelles CVEs CRITICAL |
| NeuVectorAdmissionDenied | warning | > 10 déploiements refusés/heure |

**License**:

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| NeuVectorLicenseExpiringSoon | warning | License expire dans < 30 jours |
| NeuVectorLicenseExpired | critical | License expirée |

## Network Policy

When Cilium egress policies are enabled, NeuVector has its own `CiliumNetworkPolicy` allowing:
- HTTPS (443/TCP) for CVE database updates and registry scanning

## Configuration

```yaml
# config/dev.yaml
neuvector:
  version: "2.8.4"
  controller:
    replicas: 1
  scanner:
    replicas: 1
```

## Dependencies

- **sso**: Keycloak for OIDC authentication
- **externalSecrets**: CA certificate synchronization
- **certManager**: TLS certificates

## Troubleshooting

### Controller ne démarre pas

```bash
# Vérifier les pods
kubectl get pods -n neuvector -l app=neuvector-controller-pod

# Logs du controller
kubectl logs -n neuvector -l app=neuvector-controller-pod

# Events
kubectl get events -n neuvector --sort-by='.lastTimestamp'
```

### Enforcer pas déployé sur tous les nodes

```bash
# Vérifier le DaemonSet
kubectl get daemonset -n neuvector neuvector-enforcer-pod

# Nodes sans enforcer
kubectl get pods -n neuvector -l app=neuvector-enforcer-pod -o wide

# Vérifier les tolerations si nodes tainted
kubectl describe daemonset -n neuvector neuvector-enforcer-pod | grep -A5 Tolerations
```

### OIDC ne fonctionne pas

```bash
# Vérifier le certificat CA
kubectl get secret -n neuvector keycloak-ca-cert

# Vérifier que le controller monte le CA
kubectl describe pod -n neuvector -l app=neuvector-controller-pod | grep -A5 Mounts

# Logs d'authentification
kubectl logs -n neuvector -l app=neuvector-controller-pod | grep -i auth
```

### Scanner ne trouve pas de CVEs

```bash
# Vérifier le scanner
kubectl get pods -n neuvector -l app=neuvector-scanner-pod

# Logs du scanner
kubectl logs -n neuvector -l app=neuvector-scanner-pod

# Vérifier la connectivité vers la base CVE
kubectl exec -n neuvector -l app=neuvector-scanner-pod -- wget -q --spider https://cve.mitre.org
```

### Accès UI impossible

```bash
# Vérifier le manager
kubectl get pods -n neuvector -l app=neuvector-manager-pod

# Vérifier le service
kubectl get svc -n neuvector neuvector-service-webui

# Port-forward pour test direct
kubectl port-forward -n neuvector svc/neuvector-service-webui 8443:8443
```

## References

- [NeuVector Documentation](https://open-docs.neuvector.com/)
- [NeuVector Helm Chart](https://github.com/neuvector/neuvector-helm)
