#!/bin/bash
# =============================================================================
# Detect applications to deploy based on changed files in PR
# =============================================================================
# Analyzes PR/commit changes and determines:
#   - Which ingress controller to use
#   - Which additional apps to deploy (based on dependency groups)
#   - Outputs environment variables for generate-ci-config.sh
# =============================================================================

set -euo pipefail

# Get changed files
get_changed_files() {
  if [ -n "${PR_NUMBER:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    # In GitHub Actions with PR
    gh pr view "$PR_NUMBER" --json files -q '.files[].path' 2>/dev/null || echo ""
  elif [ -n "${GITHUB_BASE_REF:-}" ]; then
    # In GitHub Actions, compare with base branch
    git fetch origin "$GITHUB_BASE_REF" --depth=1 2>/dev/null || true
    git diff --name-only "origin/$GITHUB_BASE_REF"...HEAD 2>/dev/null || echo ""
  elif git rev-parse --verify origin/main >/dev/null 2>&1; then
    # Local development, compare with main
    git diff --name-only origin/main...HEAD 2>/dev/null || echo ""
  else
    # Fallback: no changes detected, use defaults
    echo ""
  fi
}

# Check if a path pattern is modified
modified() {
  echo "$CHANGED_FILES" | grep -q "$1" 2>/dev/null
}

# =============================================================================
# Main detection logic
# =============================================================================

CHANGED_FILES=$(get_changed_files)

# Debug: show changed files
if [ -n "${DEBUG:-}" ]; then
  echo "DEBUG: Changed files:" >&2
  echo "$CHANGED_FILES" | head -20 >&2
fi

# Apps de base (toujours installees)
BASE_APPS="metallb cert-manager external-dns external-secrets cilium gateway-api-controller"
EXTRA_APPS=""
INGRESS="traefik"
STORAGE_PROVIDER="none"
SERVICE_MESH_PROVIDER="none"

# =============================================================================
# Ingress Controller Detection
# =============================================================================

if modified "apps/istio/" || modified "apps/istio-gateway/"; then
  INGRESS="istio"
  EXTRA_APPS+=" istio istio-gateway"
  SERVICE_MESH_PROVIDER="istio"
elif modified "apps/apisix/"; then
  INGRESS="apisix"
elif modified "apps/ingress-nginx/"; then
  INGRESS="ingress-nginx"
elif modified "apps/envoy-gateway/"; then
  INGRESS="envoy-gateway"
elif modified "apps/nginx-gateway-fabric/"; then
  INGRESS="nginx-gateway-fabric"
elif modified "apps/traefik/"; then
  INGRESS="traefik"
fi

# =============================================================================
# Dependency Groups
# =============================================================================

# Groupe SSO: oauth2-proxy OR keycloak -> full stack (istio + storage + db)
if modified "apps/oauth2-proxy/" || modified "apps/keycloak/"; then
  # SSO apps
  [[ ! " $EXTRA_APPS " =~ " oauth2-proxy " ]] && EXTRA_APPS+=" oauth2-proxy"
  [[ ! " $EXTRA_APPS " =~ " keycloak " ]] && EXTRA_APPS+=" keycloak"
  [[ ! " $EXTRA_APPS " =~ " cnpg-operator " ]] && EXTRA_APPS+=" cnpg-operator"
  # Istio for ext_authz (AuthorizationPolicy)
  [[ ! " $EXTRA_APPS " =~ " istio " ]] && EXTRA_APPS+=" istio"
  [[ ! " $EXTRA_APPS " =~ " istio-gateway " ]] && EXTRA_APPS+=" istio-gateway"
  INGRESS="istio"
  SERVICE_MESH_PROVIDER="istio"
  # Storage for PostgreSQL PVC
  [[ ! " $EXTRA_APPS " =~ " longhorn " ]] && EXTRA_APPS+=" longhorn"
  [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
  STORAGE_PROVIDER="longhorn"
fi

# Groupe Monitoring: any observability component -> install prometheus-stack
if modified "apps/prometheus-stack/" || modified "apps/alloy/" || \
   modified "apps/tempo/" || modified "apps/jaeger/" || modified "apps/loki/"; then
  [[ ! " $EXTRA_APPS " =~ " prometheus-stack " ]] && EXTRA_APPS+=" prometheus-stack"

  # Prometheus-stack requires storage for TSDB, Alertmanager, Grafana
  if modified "apps/prometheus-stack/"; then
    [[ ! " $EXTRA_APPS " =~ " longhorn " ]] && EXTRA_APPS+=" longhorn"
    [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
    STORAGE_PROVIDER="longhorn"
  fi

  # Add the specific component that was modified
  modified "apps/alloy/" && [[ ! " $EXTRA_APPS " =~ " alloy " ]] && EXTRA_APPS+=" alloy"
  modified "apps/tempo/" && [[ ! " $EXTRA_APPS " =~ " tempo " ]] && EXTRA_APPS+=" tempo"
  modified "apps/jaeger/" && [[ ! " $EXTRA_APPS " =~ " jaeger " ]] && EXTRA_APPS+=" jaeger"
  modified "apps/loki/" && [[ ! " $EXTRA_APPS " =~ " loki " ]] && EXTRA_APPS+=" loki"

  # Loki requires storage for log data
  if modified "apps/loki/"; then
    [[ ! " $EXTRA_APPS " =~ " longhorn " ]] && EXTRA_APPS+=" longhorn"
    [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
    STORAGE_PROVIDER="longhorn"
  fi

  # Tracing (tempo/jaeger) requires Istio to generate traces
  if modified "apps/tempo/" || modified "apps/jaeger/"; then
    [[ ! " $EXTRA_APPS " =~ " istio " ]] && EXTRA_APPS+=" istio"
    [[ ! " $EXTRA_APPS " =~ " istio-gateway " ]] && EXTRA_APPS+=" istio-gateway"
    INGRESS="istio"
    SERVICE_MESH_PROVIDER="istio"
  fi
fi

# Groupe Storage: longhorn OR rook -> install + csi-external-snapshotter
if modified "apps/longhorn/"; then
  [[ ! " $EXTRA_APPS " =~ " longhorn " ]] && EXTRA_APPS+=" longhorn"
  [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
  # Prometheus uses Longhorn storage + monitors Longhorn metrics
  [[ ! " $EXTRA_APPS " =~ " prometheus-stack " ]] && EXTRA_APPS+=" prometheus-stack"
  STORAGE_PROVIDER="longhorn"
fi

if modified "apps/rook/"; then
  [[ ! " $EXTRA_APPS " =~ " rook " ]] && EXTRA_APPS+=" rook"
  [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
  # Prometheus uses Rook storage + monitors Ceph metrics
  [[ ! " $EXTRA_APPS " =~ " prometheus-stack " ]] && EXTRA_APPS+=" prometheus-stack"
  STORAGE_PROVIDER="rook"
fi

# Note: Kiali is part of the Istio app (not a separate app)
# It's enabled via istio config: kiali.enabled=true

# ArgoCD: always deployed, but track if modified for specific testing
if modified "apps/argocd/"; then
  [[ ! " $EXTRA_APPS " =~ " argocd " ]] && EXTRA_APPS+=" argocd"
fi

# CNPG Operator: requires storage for PostgreSQL clusters
if modified "apps/cnpg-operator/"; then
  [[ ! " $EXTRA_APPS " =~ " cnpg-operator " ]] && EXTRA_APPS+=" cnpg-operator"
  [[ ! " $EXTRA_APPS " =~ " longhorn " ]] && EXTRA_APPS+=" longhorn"
  [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
  STORAGE_PROVIDER="longhorn"
fi

# Standalone components
# NeuVector requires storage for controller database
if modified "apps/neuvector/"; then
  [[ ! " $EXTRA_APPS " =~ " neuvector " ]] && EXTRA_APPS+=" neuvector"
  [[ ! " $EXTRA_APPS " =~ " longhorn " ]] && EXTRA_APPS+=" longhorn"
  [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"
  STORAGE_PROVIDER="longhorn"
fi
modified "apps/kube-vip/" && [[ ! " $EXTRA_APPS " =~ " kube-vip " ]] && EXTRA_APPS+=" kube-vip"
modified "apps/csi-external-snapshotter/" && [[ ! " $EXTRA_APPS " =~ " csi-external-snapshotter " ]] && EXTRA_APPS+=" csi-external-snapshotter"

# =============================================================================
# Output
# =============================================================================

# Trim leading/trailing spaces
EXTRA_APPS=$(echo "$EXTRA_APPS" | xargs)
ALL_APPS="$BASE_APPS $INGRESS $EXTRA_APPS"
ALL_APPS=$(echo "$ALL_APPS" | xargs)

# Detect which components are in the apps list for conditional tests
CNPG_ENABLED="false"
[[ " $ALL_APPS " =~ " cnpg-operator " ]] && CNPG_ENABLED="true"

PROMETHEUS_ENABLED="false"
[[ " $ALL_APPS " =~ " prometheus-stack " ]] && PROMETHEUS_ENABLED="true"

SSO_ENABLED="false"
[[ " $ALL_APPS " =~ " oauth2-proxy " ]] || [[ " $ALL_APPS " =~ " keycloak " ]] && SSO_ENABLED="true"

NEUVECTOR_ENABLED="false"
[[ " $ALL_APPS " =~ " neuvector " ]] && NEUVECTOR_ENABLED="true"

ARGOCD_MODIFIED="false"
[[ " $EXTRA_APPS " =~ " argocd " ]] && ARGOCD_MODIFIED="true"

# Export for use by other scripts
echo "INGRESS=$INGRESS"
echo "EXTRA_APPS=$EXTRA_APPS"
echo "ALL_APPS=$ALL_APPS"
echo "STORAGE_PROVIDER=$STORAGE_PROVIDER"
echo "SERVICE_MESH_PROVIDER=$SERVICE_MESH_PROVIDER"
echo "CNPG_ENABLED=$CNPG_ENABLED"
echo "PROMETHEUS_ENABLED=$PROMETHEUS_ENABLED"
echo "SSO_ENABLED=$SSO_ENABLED"
echo "NEUVECTOR_ENABLED=$NEUVECTOR_ENABLED"
echo "ARGOCD_MODIFIED=$ARGOCD_MODIFIED"

# If running in GitHub Actions, set outputs
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "ingress=$INGRESS" >> "$GITHUB_OUTPUT"
  echo "extra_apps=$EXTRA_APPS" >> "$GITHUB_OUTPUT"
  echo "all_apps=$ALL_APPS" >> "$GITHUB_OUTPUT"
  echo "storage_provider=$STORAGE_PROVIDER" >> "$GITHUB_OUTPUT"
  echo "service_mesh_provider=$SERVICE_MESH_PROVIDER" >> "$GITHUB_OUTPUT"
  echo "cnpg_enabled=$CNPG_ENABLED" >> "$GITHUB_OUTPUT"
  echo "prometheus_enabled=$PROMETHEUS_ENABLED" >> "$GITHUB_OUTPUT"
  echo "sso_enabled=$SSO_ENABLED" >> "$GITHUB_OUTPUT"
  echo "neuvector_enabled=$NEUVECTOR_ENABLED" >> "$GITHUB_OUTPUT"
  echo "argocd_modified=$ARGOCD_MODIFIED" >> "$GITHUB_OUTPUT"
fi

# Summary
echo ""
echo "=== CI Apps Detection Summary ==="
echo "Ingress Controller: $INGRESS"
echo "Extra Apps: ${EXTRA_APPS:-none}"
echo "Storage Provider: $STORAGE_PROVIDER"
echo "Service Mesh: $SERVICE_MESH_PROVIDER"
echo "All Apps: $ALL_APPS"
