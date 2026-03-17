---
description: Complete checklist for adding a new application to the GitOps infrastructure
globs: ["deploy/argocd/apps/*/applicationset.yaml", "deploy/argocd/apps/*/config/*.yaml"]
---

# New Application Checklist

Every item marked **MANDATORY** must be present. Items marked **CONDITIONAL** depend on the app's features.

## 1. Directory Structure (MANDATORY)

```bash
mkdir -p deploy/argocd/apps/<app-name>/{config,resources,kustomize}
```

Required files: `applicationset.yaml`, `config/dev.yaml`, `config/prod.yaml`, `README.md`

## 2. ApplicationSet Definition (MANDATORY)

- `goTemplate: true` + `goTemplateOptions: ["missingkey=error"]`
- Git Merge Generator (global config + app-specific config)
- `templatePatch` with conditional sources
- `syncPolicy` with retry (10 retries, 10s/2x/10m backoff)
- `syncOptions` from config (including `ServerSideApply=true` if CRDs are large)
- **ignoreDifferences** (CONDITIONAL — apps with CRDs/operators): ignore `.status`, controller-enriched fields (`.spec.configuration`, `.spec.config`), ExternalSecret defaults, SecurityPolicy defaults. Add `RespectIgnoreDifferences=true` in syncOptions.

Sources checklist (each conditional on its feature flag):

| Source | Condition | Path type |
|--------|-----------|-----------|
| Namespace (PSA labels) | `rke2.cis.enabled` | `resources/` + `directory.include` |
| Kyverno PolicyException | `features.kyverno.enabled` | `resources/` + `directory.include` |
| Main app (Helm/Kustomize) | Always | `helm:` or `kustomize:` |
| Network policies (internal) | `features.networkPolicy.defaultDenyPodIngress.enabled` | `resources/` + CNI branching |
| Network policies (egress) | `features.networkPolicy.egressPolicy.enabled` | `resources/` + CNI branching |
| Network policies (host ingress) | `features.networkPolicy.ingressPolicy.enabled` | `resources/` + CNI + provider branching |
| HTTPRoute / APISIX | `features.gatewayAPI.enabled` | See routing section |
| Monitoring | `features.monitoring.enabled` | `kustomize/monitoring/` |
| SSO Keycloak | `features.sso.enabled` + `provider == "keycloak"` | `kustomize/sso-keycloak/` |

## 3. Environment Config (MANDATORY)

Files: `config/dev.yaml`, `config/prod.yaml`

- `environment`, `appName`, version(s), `syncPolicy.syncOptions` (CreateNamespace, ServerSideApply), `syncPolicy.automated` (true for dev, false for prod), per-env tuning

## 4. Namespace Resources (CONDITIONAL — when CIS profile active)

Files: `resources/namespace.yaml` (+ `namespace-<secondary>.yaml` if multi-namespace)

- PSA labels: `enforce: privileged` (if host access needed) or `restricted`, `warn: restricted`, `audit: restricted`
- Conditional on `{{- if .rke2.cis.enabled }}`

## 5. Kyverno PolicyExceptions (CONDITIONAL — when app needs SA tokens)

Files: `resources/kyverno-policy-exception.yaml` (one per namespace)

- `sync-wave: "-5"` (regular resource, NOT PreSync hook)
- Covers `automount-sa-token` policy, scoped to app namespace only

## 6. Network Policies (CONDITIONAL)

**Internal ingress** (`defaultDenyPodIngress.enabled`): `resources/{cilium,calico}-ingress-policy.yaml`
- **NEVER use `fromEndpoints: [{}]` or `source: selector: all()`** — restrict to specific namespaces
- Allow intra-namespace, `monitoring` (Prometheus scrape with ports), `oauth2-proxy` (if UI), cross-namespace if multi-ns
- Cilium: `io.kubernetes.pod.namespace` label. Calico: `kubernetes.io/metadata.name == "ns"` selector

**Egress** (`egressPolicy.enabled`): `resources/{cilium,calico}-egress-policy.yaml`
- Allow kube-apiserver (6443/TCP), DNS (53/UDP+TCP), app-specific (e.g., 80/443 for imports)

**Host ingress per provider** (`ingressPolicy.enabled`): 12 files (6 providers x 2 CNIs)
- `resources/{cilium,calico}-ingress-policy-{envoy-gateway,istio,apisix,traefik,nginx-gwf,cilium}.yaml`
- Conditional via `features.gatewayAPI.controller.provider` branching

## 7. Routing — Gateway API + OAuth2/SSO (CONDITIONAL)

**Base HTTPRoute**: `kustomize/httproute/` — HTTPRoute with PLACEHOLDERs patched via ApplicationSet

**ApplicationSet branching pattern** (for apps with UI):

```
if gatewayAPI.enabled:
  if httpRoute.enabled:
    if oauth2Proxy.enabled && provider == "istio":
      → kustomize/httproute-oauth2-istio/ (HTTPRoute + AuthorizationPolicy)
    elif oauth2Proxy.enabled && provider == "envoy-gateway":
      → kustomize/httproute-oauth2-envoy-gateway/ (HTTPRoute + SecurityPolicy + ExternalSecrets)
    elif oauth2Proxy.enabled && provider == "traefik":
      → kustomize/httproute/ (patches: /oauth2/ route + Middleware ExtensionRef)
      → kustomize/oauth2-authz-traefik/ (Middleware + ReferenceGrant)
    else:
      → kustomize/httproute/ (standard, no auth)
  elif provider == "apisix":
    → kustomize/apisix/ (ApisixRoute + ApisixUpstream with forward-auth)
```

**Envoy Gateway OIDC**: `kustomize/httproute-oauth2-envoy-gateway/` — kustomization.yaml (includes `../httproute`), backend-keycloak.yaml, external-secret-ca.yaml, oidc-secret.yaml, security-policy.yaml. Patches: hostname, gateway ns, keycloak domain, issuer, endpoints, redirect URL.

**Istio ext_authz**: `kustomize/httproute-oauth2-istio/` — kustomization.yaml (includes `../httproute`), authorization-policy.yaml (CUSTOM action, in `istio-system`). Patches: hostname, gateway ns, host.

**Traefik Middleware**: `kustomize/oauth2-authz-traefik/` — middleware.yaml (chain → `forward-auth` in `oauth2-proxy`), oauth2-proxy-referencegrant.yaml. Patches on HTTPRoute: add `/oauth2/` route + ExtensionRef filter.

**APISIX native**: `kustomize/apisix/` — oauth2-proxy-upstream.yaml (Domain type), apisix-route.yaml (2 routes: `/oauth2/*` + `/*` with forward-auth + serverless-post-function 401→302). Patches: hostname.

**Keycloak SSO**: `kustomize/sso-keycloak/` — Job (Sync hook, `hook-delete-policy: HookSucceeded`) registering redirect URIs. Waits for Keycloak (240s) + realm (120s), adds redirectUris/webOrigins/post-logout. Image patched via `kustomize.images`. Patches: domain.

## 8. Monitoring (CONDITIONAL — when `monitoring.enabled`)

Directory: `kustomize/monitoring/`

- ServiceMonitors (`selector.matchLabels` matching Services), Services (metrics endpoints per component), PrometheusRules
- Grafana dashboard ConfigMap (label `grafana_dashboard: "1"`, annotation `grafana_dashboard_folder`)
- `commonLabels` via ApplicationSet: `release: '{{ .features.monitoring.release }}'`

## 9. Global Integration (MANDATORY)

- **config/config.yaml**: add feature flag under `features:`
- **deploy-applicationsets.sh**: `FEAT_<APP>` via `get_feature`, `log_debug`, `resolve_dependencies` (implicit deps), `validate_dependencies` (hard requirements), add to `APPLICATIONSETS` array, add to summary echo
- **renovate.json**: custom regex manager(s), `managerFilePatterns`, `datasourceTemplate`, `groupName`
- **CLAUDE.md**: add feature flag to Feature Flag Conditions table

## 10. Audit Rules (CONDITIONAL — apps with security-relevant CRDs)

File: `audit-rules.yaml` — bare YAML list items (no `rules:` wrapper), `Metadata` for routine, `RequestResponse` for security-critical

## 11. README (MANDATORY)

Overview, components table, prerequisites, feature flags, config details, architecture diagram, monitoring, dev/prod differences, troubleshooting, external docs links
