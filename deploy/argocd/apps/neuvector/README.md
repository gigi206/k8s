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

## References

- [NeuVector Documentation](https://open-docs.neuvector.com/)
- [NeuVector Helm Chart](https://github.com/neuvector/neuvector-helm)
