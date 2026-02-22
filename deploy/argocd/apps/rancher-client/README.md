# Rancher Client

Registers this cluster as a downstream cluster in an external Rancher server by deploying the `cattle-cluster-agent`.

## Overview

This application deploys the Rancher cattle-cluster-agent which connects back to a Rancher management server, allowing the cluster to be managed remotely.

## Prerequisites

- An external Rancher server accessible from this cluster
- An import URL generated from Rancher UI (Cluster Management > Import Existing)
- Traefik (if used as ingress on the Rancher server) must have WebSocket timeouts disabled (`readTimeout=0`, `idleTimeout=0`) to avoid tunnel disconnects

## Configuration

### Generate configuration from Rancher import URL

```bash
cd deploy/argocd/apps/rancher-client
./scripts/generate.sh "https://rancher.example.com/v3/import/TOKEN_c-CLUSTERID.yaml"
```

This extracts server info, credentials, and agent image from the Rancher manifest and generates `config/dev.yaml`. Feature flags (`ciliumEgressPolicy`, `kyvernoPolicyException`, `cisNamespace`) are automatically derived from `deploy/argocd/config/config.yaml`.

For production:

```bash
./scripts/generate.sh "https://rancher.example.com/v3/import/TOKEN_c-CLUSTERID.yaml" prod
```

### Configuration parameters

| Parameter | Description |
|-----------|-------------|
| `rancherClient.server.url` | Rancher server URL |
| `rancherClient.server.ip` | Rancher server IP |
| `rancherClient.server.caChecksum` | CA certificate checksum for TLS verification |
| `rancherClient.server.version` | Rancher server version |
| `rancherClient.server.installUUID` | Rancher installation UUID |
| `rancherClient.server.ingressIpDomain` | Ingress IP domain (e.g., sslip.io) |
| `rancherClient.credentials.secretName` | Name of the credentials Secret |
| `rancherClient.credentials.url` | Base64-encoded Rancher URL |
| `rancherClient.credentials.token` | Base64-encoded registration token |
| `rancherClient.agent.image` | cattle-cluster-agent container image |

### Feature flags

Derived automatically from `deploy/argocd/config/config.yaml` by the scripts:

| Flag | Source | Effect |
|------|--------|--------|
| `features.ciliumEgressPolicy` | `cni.primary=cilium` + `features.networkPolicy.egressPolicy.enabled` | CiliumNetworkPolicy for egress (FQDN + kube-apiserver + DNS) |
| `features.kyvernoPolicyException` | `features.kyverno.enabled` | PolicyException for SA token automount |
| `features.cisNamespace` | `rke2.cis.enabled` | PSA privileged labels on cattle-* namespaces |

### Direct deployment (without ArgoCD)

For testing or initial setup, deploy directly via Helm:

```bash
cd deploy/argocd/apps/rancher-client
./scripts/deploy.sh "https://rancher.example.com/v3/import/TOKEN_c-CLUSTERID.yaml"
```

This downloads the Rancher manifest, extracts all parameters, reads feature flags from `config/config.yaml`, pre-creates namespaces and Kyverno PolicyExceptions (to avoid race conditions), and runs `helm upgrade --install`.

## Deployed resources

- **Namespaces**: `cattle-system`, `cattle-fleet-system`, `cattle-impersonation-system`, `cattle-local-user-passwords` (with PSA labels if CIS enabled)
- **Deployment**: `cattle-cluster-agent` (connects to Rancher server via WebSocket tunnel)
- **Service**: `cattle-cluster-agent` (ports 80, 443)
- **Secret**: credentials for Rancher server authentication (token, url)
- **RBAC**: `cattle-admin` ClusterRole + ServiceAccount + ClusterRoleBindings
- **PolicyException** (if kyverno): Kyverno exception for SA token automount in `cattle-system` and `cattle-fleet-system`
- **ClusterPolicy** (if kyverno + CIS): `rancher-enforce-psa-privileged` - mutates cattle-* namespaces to always carry PSA `privileged` labels (Rancher overwrites them during cluster registration)
- **CiliumNetworkPolicy** (if cilium + egress): FQDN-based egress to Rancher server, `kube-apiserver` entity, and DNS access for `cattle-system` and `cattle-fleet-system`

## Known issues

- **Rancher overwrites PSA labels**: When Rancher registers a downstream cluster, it overwrites namespace labels, removing `pod-security.kubernetes.io/enforce=privileged`. The Kyverno ClusterPolicy `rancher-enforce-psa-privileged` mitigates this by re-applying the labels via mutation.
- **Helm SSA conflicts**: Rancher modifies the Deployment after initial install (via `kubectl-client-side-apply`). Subsequent `helm upgrade` may fail with field manager conflicts. Use `--force` or delete and recreate.
- **Traefik WebSocket timeout**: If Rancher runs behind Traefik (e.g., k3d), the default `readTimeout` (60s) kills the agent tunnel. Apply a `HelmChartConfig` to set `readTimeout=0` and `idleTimeout=0` on the `websecure` entrypoint.
