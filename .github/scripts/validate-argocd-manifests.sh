#!/bin/bash
# =============================================================================
# Validate ArgoCD ApplicationSet manifests and configurations
# =============================================================================
# Validates:
#   1. YAML syntax for all ApplicationSets
#   2. Go template syntax
#   3. Required fields are present
#   4. Version fields in config files
#   5. Helm chart references are valid
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPS_DIR="$REPO_ROOT/deploy/argocd/apps"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[FAIL]${RESET} $*"; }

ERRORS=0
WARNINGS=0

# =============================================================================
# Validation Functions
# =============================================================================

validate_yaml_syntax() {
  local file="$1"
  if yq eval '.' "$file" >/dev/null 2>&1; then
    return 0
  else
    log_error "Invalid YAML syntax: $file"
    yq eval '.' "$file" 2>&1 | head -5
    return 1
  fi
}

validate_applicationset() {
  local appset_file="$1"
  local app_name
  app_name=$(basename "$(dirname "$appset_file")")

  log_info "Validating ApplicationSet: $app_name"

  # Check YAML syntax
  if ! validate_yaml_syntax "$appset_file"; then
    ((ERRORS++))
    return 1
  fi

  # Check required fields
  local kind
  kind=$(yq '.kind' "$appset_file" 2>/dev/null)
  if [ "$kind" != "ApplicationSet" ]; then
    log_error "$app_name: kind must be 'ApplicationSet', got '$kind'"
    ((ERRORS++))
    return 1
  fi

  # Check metadata.name exists
  local name
  name=$(yq '.metadata.name' "$appset_file" 2>/dev/null)
  if [ -z "$name" ] || [ "$name" = "null" ]; then
    log_error "$app_name: metadata.name is required"
    ((ERRORS++))
    return 1
  fi

  # Check generators exist
  local generators
  generators=$(yq '.spec.generators | length' "$appset_file" 2>/dev/null)
  if [ "$generators" = "0" ] || [ "$generators" = "null" ]; then
    log_error "$app_name: spec.generators is required"
    ((ERRORS++))
    return 1
  fi

  # Check template exists
  local template
  template=$(yq '.spec.template' "$appset_file" 2>/dev/null)
  if [ "$template" = "null" ]; then
    log_error "$app_name: spec.template is required"
    ((ERRORS++))
    return 1
  fi

  # Check for common Go template issues
  if grep -q '{{[^}]*\.\.[^}]*}}' "$appset_file" 2>/dev/null; then
    log_warning "$app_name: Found '..' in template, may be typo"
    ((WARNINGS++))
  fi

  # Check sync-wave annotation exists
  local sync_wave
  sync_wave=$(yq '.spec.template.metadata.annotations."argocd.argoproj.io/sync-wave"' "$appset_file" 2>/dev/null)
  if [ -z "$sync_wave" ] || [ "$sync_wave" = "null" ]; then
    log_warning "$app_name: No sync-wave annotation defined"
    ((WARNINGS++))
  fi

  log_success "$app_name: ApplicationSet is valid"
  return 0
}

validate_config_file() {
  local config_file="$1"
  local app_name
  app_name=$(basename "$(dirname "$(dirname "$config_file")")")
  local env
  env=$(basename "$config_file" .yaml)

  log_info "Validating config: $app_name/$env"

  # Check YAML syntax
  if ! validate_yaml_syntax "$config_file"; then
    ((ERRORS++))
    return 1
  fi

  # Check for version field (common pattern)
  local version_fields
  version_fields=$(yq '.. | select(has("version")) | .version' "$config_file" 2>/dev/null | head -5)

  if [ -n "$version_fields" ]; then
    while IFS= read -r version; do
      if [ -n "$version" ] && [ "$version" != "null" ]; then
        # Validate version format (should be semver-ish)
        if [[ ! "$version" =~ ^[0-9]+\.[0-9]+ ]]; then
          log_warning "$app_name/$env: Version '$version' doesn't look like semver"
          ((WARNINGS++))
        fi
      fi
    done <<< "$version_fields"
  fi

  log_success "$app_name/$env: Config is valid"
  return 0
}

validate_helm_sources() {
  local appset_file="$1"
  local app_name
  app_name=$(basename "$(dirname "$appset_file")")

  # Extract Helm repository URLs
  local helm_repos
  helm_repos=$(yq '.spec.template.spec.sources[] | select(.chart) | .repoURL' "$appset_file" 2>/dev/null | sort -u)

  if [ -n "$helm_repos" ]; then
    while IFS= read -r repo; do
      if [ -n "$repo" ] && [ "$repo" != "null" ]; then
        # Check if repo URL is valid format
        if [[ ! "$repo" =~ ^(https?://|oci://) ]]; then
          log_warning "$app_name: Helm repo URL looks invalid: $repo"
          ((WARNINGS++))
        fi
      fi
    done <<< "$helm_repos"
  fi
}

# =============================================================================
# Main
# =============================================================================

log_info "Validating ArgoCD manifests in: $APPS_DIR"
echo ""

# Find and validate all ApplicationSets
log_info "=== Validating ApplicationSets ==="
while IFS= read -r -d '' appset_file; do
  validate_applicationset "$appset_file"
  validate_helm_sources "$appset_file"
done < <(find "$APPS_DIR" -name "applicationset.yaml" -print0 2>/dev/null)

echo ""

# Find and validate all config files
log_info "=== Validating Config Files ==="
while IFS= read -r -d '' config_file; do
  validate_config_file "$config_file"
done < <(find "$APPS_DIR" -path "*/config/*.yaml" -print0 2>/dev/null)

echo ""

# =============================================================================
# Summary
# =============================================================================

echo "=============================================="
echo "       Validation Summary"
echo "=============================================="
echo ""
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  log_error "Validation failed with $ERRORS error(s)"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  log_warning "Validation passed with $WARNINGS warning(s)"
else
  log_success "All validations passed!"
fi

exit 0
