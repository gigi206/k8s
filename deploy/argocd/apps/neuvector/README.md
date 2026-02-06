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

A PostSync Job (`controller-ca-patch-job.yaml`) patches the controller deployment to:
1. Add an **initContainer** (`wait-for-ca`) that waits for the CA certificate to be ready
2. Mount the cluster CA certificate (`root-ca` secret) for OIDC TLS verification
3. Set `SSL_CERT_FILE` environment variable

**Note** : Lors d'une première installation, une erreur x509 temporaire peut apparaître car le deployment est créé par Helm avant que le PostSync Job ne puisse le patcher. Après le patch, l'initContainer garantit que les pods attendent le CA avant de démarrer.

## Monitoring

### Prometheus Exporter

The Prometheus exporter collects metrics from NeuVector.

#### Enforcer Stats (Performance Impact)

By default, Controller and Enforcer CPU/Memory metrics are **disabled** for performance reasons. Enable only if needed:

```yaml
# config/dev.yaml
neuvector:
  exporter:
    enforcerStats:
      enabled: true  # WARNING: impacts performance
```

When enabled, the exporter exposes the following metrics for the Grafana dashboard:
- `nv_controller_cpu` / `nv_controller_memory` - Controller resource usage
- `nv_enforcer_cpu` / `nv_enforcer_memory` - Enforcer resource usage

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

## Known Issues

### Bug RBAC avec cert-manager (Chart Helm 2.8.x)

**Symptômes** :
- Controller pods: `0/1 Running` (jamais Ready)
- prometheus-exporter: `CrashLoopBackOff` (dépend du controller)
- Logs du controller :
  ```
  ERRO|CTL|resource.VerifyNvRbacRoles: Cannot find Kubernetes role "neuvector-binding-secret-controller"
  ERRO|CTL|resource.VerifyNvRbacRoleBindings: Cannot find Kubernetes rolebinding "neuvector-binding-secret-controller"
  ```

**Cause racine** : Bug dans le chart Helm NeuVector (toutes versions 2.8.x).

Le chart crée le Role `neuvector-binding-secret-controller` uniquement si `internal.autoGenerateCert=true` :

```yaml
# templates/role.yaml (ligne 29)
{{- if .Values.internal.autoGenerateCert }}
...
kind: Role
metadata:
  name: neuvector-binding-secret-controller
...
{{- end }}
```

Quand on utilise cert-manager (`internal.certmanager.enabled=true`), on doit désactiver `autoGenerateCert=false` pour éviter les conflits. Résultat : le Role n'est pas créé.

**Mais** le controller NeuVector vérifie **toujours** l'existence de ce Role au démarrage, indépendamment de la méthode de gestion des certificats.

**Workaround** : L'ApplicationSet inclut une source Kustomize (`kustomize/rbac/`) qui crée les RBAC manquants :
- `Role/neuvector-binding-secret-controller`
- `RoleBinding/neuvector-binding-secret-controller`

**Vérification** :
```bash
# Les RBAC doivent exister
kubectl get role,rolebinding -n neuvector | grep secret-controller
# role.rbac.authorization.k8s.io/neuvector-binding-secret-controller
# rolebinding.rbac.authorization.k8s.io/neuvector-binding-secret-controller
```

**Fix attendu upstream** : La condition devrait être `{{- if or .Values.internal.autoGenerateCert .Values.internal.certmanager.enabled }}`

---

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

**Si erreur RBAC** : Voir la section [Bug RBAC avec cert-manager](#bug-rbac-avec-cert-manager-chart-helm-28x) ci-dessus.

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

### Envoy Gateway: upstream connect error

Si vous utilisez Envoy Gateway et obtenez cette erreur:
```
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

**Cause**: NeuVector Manager ne supporte que HTTP/1.1, mais Envoy Gateway utilise HTTP/2 par defaut via ALPN pour les backends TLS.

**Solution**: Un `Backend` CRD specifique avec `alpnProtocols: ["http/1.1"]` est utilise automatiquement quand `features.gatewayAPI.controller.provider = "envoy-gateway"`.

```bash
# Verifier que le Backend est deploye
kubectl get backend -n neuvector neuvector-manager-backend -o yaml

# Verifier les logs Envoy
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=default-gateway

# Test direct HTTP/1.1 depuis un pod
kubectl run -it --rm curl --image=curlimages/curl -- curl -k --http1.1 https://neuvector-service-webui.neuvector.svc.cluster.local:8443
```

### Cilium Gateway: HTTPS backend non supporté

Cilium Gateway API ne supporte **pas** `BackendTLSPolicy` (voir [cilium/cilium#31352](https://github.com/cilium/cilium/issues/31352)). Le champ `appProtocol: https` n'est pas non plus pris en charge pour les connexions HTTPS vers les backends (seul `kubernetes.io/h2c` est reconnu pour HTTP/2, voir [cilium/cilium#30452](https://github.com/cilium/cilium/issues/30452)).

NeuVector Manager écoute **uniquement en HTTPS** sur le port 8443. Sans mécanisme pour indiquer au gateway de se connecter en HTTPS, les connexions échouent avec :
```
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

**Limitation actuelle** : Contrairement à Rook (qui utilise un reverse proxy HTTP-to-HTTPS comme workaround), NeuVector n'a pas encore de solution implémentée pour Cilium Gateway. Une approche similaire (reverse proxy nginx dans le namespace neuvector) serait nécessaire.

**Providers supportés** :
| Provider | Support HTTPS backend | Mécanisme |
|----------|-----------------------|-----------|
| APISIX | `appProtocol: https` sur le Service | Détection automatique |
| nginx-gateway-fabric | `BackendTLSPolicy` | Gateway API standard |
| Envoy Gateway | `Backend` CRD avec `appProtocol: https` | CRD natif |
| Cilium | **Non supporté** | Pas de BackendTLSPolicy, pas d'appProtocol |

> **Note** : Ce problème sera résolu quand Cilium implémentera le support de `BackendTLSPolicy`. En attendant, un reverse proxy HTTP-to-HTTPS (comme celui de Rook) peut être mis en place.

## References

- [NeuVector Documentation](https://open-docs.neuvector.com/)
- [NeuVector Helm Chart](https://github.com/neuvector/neuvector-helm)
