#!/bin/bash
# =============================================================================
# Deploy ApplicationSets Directly (No App of Apps)
# =============================================================================
# Applique tous les ApplicationSets directement dans le cluster
# Usage: ./deploy-applicationsets.sh [OPTIONS]
# Options:
#   -e, --env ENV         Environment (dev/prod/local, auto-detect if not set)
#   -v, --verbose         Enable verbose output
#   -t, --timeout SECS    Global timeout in seconds (default: 600)
#   -w, --wait-healthy    Wait until all apps are synced and healthy (no timeout)
#   -h, --help            Show this help
# =============================================================================

set -e

# =============================================================================
# Configuration & Variables
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argo-cd}"

# Timeouts (configurables via variables d'environnement)
TIMEOUT_APPSETS="${TIMEOUT_APPSETS:-120}"
# ApplicationSets have requeueAfter=3m, so we need at least 240s for generation
TIMEOUT_APPS_GENERATION="${TIMEOUT_APPS_GENERATION:-240}"
TIMEOUT_APPS_SYNC="${TIMEOUT_APPS_SYNC:-900}"
TIMEOUT_API_LB="${TIMEOUT_API_LB:-60}"

# Nombre d'applications attendues (sera calculé dynamiquement)
EXPECTED_APPS_COUNT=0

# Options
VERBOSE=0
ENVIRONMENT=""
GLOBAL_TIMEOUT=""
WAIT_HEALTHY=0

# Couleurs (désactivées si NO_COLOR est défini)
if [[ -z "${NO_COLOR}" ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  BOLD=''
  RESET=''
fi

# =============================================================================
# Fonctions utilitaires
# =============================================================================

log_info() {
  echo -e "${BLUE}[INFO]${RESET} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${RESET} $*"
}

log_warning() {
  echo -e "${YELLOW}[⚠]${RESET} $*"
}

log_error() {
  echo -e "${RED}[✗]${RESET} $*" >&2
}

log_debug() {
  if [[ $VERBOSE -eq 1 ]]; then
    echo -e "${BLUE}[DEBUG]${RESET} $*"
  fi
}

show_help() {
  cat << EOF
Usage: $0 [OPTIONS]

Deploy ArgoCD ApplicationSets to the cluster.

Options:
  -e, --env ENV         Environment (dev/prod/local, auto-detect if not set)
  -v, --verbose         Enable verbose output
  -t, --timeout SECS    Global timeout in seconds (default: 600)
  -w, --wait-healthy    Wait until all apps are synced and healthy (no timeout)
  -h, --help            Show this help

Environment Variables:
  K8S_ENV               Environment name (dev/prod/local)
  KUBECONFIG            Path to kubeconfig file
  ARGOCD_NAMESPACE      ArgoCD namespace (default: argo-cd)
  TIMEOUT_APPSETS       Timeout for ApplicationSets creation (default: 120s)
  TIMEOUT_APPS_GENERATION  Timeout for Applications generation (default: 60s)
  TIMEOUT_APPS_SYNC     Timeout for Applications sync (default: 300s)
  TIMEOUT_API_LB        Timeout for API LoadBalancer IP (default: 60s)
  NO_COLOR              Disable colored output

Examples:
  $0                    # Auto-detect environment
  $0 -e dev             # Deploy to dev environment
  $0 -v -t 900          # Verbose with 900s timeout
  $0 -w                 # Wait until all apps are healthy (no timeout)
  VERBOSE=1 $0          # Verbose via env var

EOF
  exit 0
}

# Fonction d'attente avec timeout et condition
# Usage: wait_for_condition "description" timeout condition_function
wait_for_condition() {
  local description="$1"
  local timeout="$2"
  local condition_func="$3"
  local elapsed=0
  local interval=5

  log_info "$description"

  while true; do
    if $condition_func; then
      return 0
    fi

    if [[ $elapsed -ge $timeout ]]; then
      log_warning "Timeout après ${timeout}s: $description"
      return 1
    fi

    # Barre de progression simple
    local progress=$((elapsed * 100 / timeout))
    printf "\r  Progression: [%-50s] %d%% (%ds/%ds)" \
      "$(printf '#%.0s' $(seq 1 $((progress / 2))))" \
      "$progress" "$elapsed" "$timeout"

    sleep $interval
    elapsed=$((elapsed + interval))
  done
}

# Validation des prérequis
validate_prerequisites() {
  log_info "Validation des prérequis..."

  local missing_tools=()

  if ! command -v kubectl &> /dev/null; then
    missing_tools+=("kubectl")
  fi

  if ! command -v jq &> /dev/null; then
    missing_tools+=("jq")
  fi

  if ! command -v yq &> /dev/null; then
    missing_tools+=("yq")
  fi

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_error "Outils manquants: ${missing_tools[*]}"
    log_error "Installez-les avant de continuer."
    exit 1
  fi

  # Vérifier la connexion au cluster
  if ! kubectl cluster-info &> /dev/null; then
    log_error "Impossible de se connecter au cluster Kubernetes"
    log_error "Vérifiez votre KUBECONFIG: ${KUBECONFIG:-~/.kube/config}"
    exit 1
  fi

  log_success "Prérequis validés"
}

# Détection automatique de l'environnement
detect_environment() {
  if [[ -n "$ENVIRONMENT" ]]; then
    echo "$ENVIRONMENT"
    return
  fi

  if [[ -n "$K8S_ENV" ]]; then
    echo "$K8S_ENV"
    return
  fi

  # Détecter via kubeconfig
  local kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
  if [[ -f "$kubeconfig" ]]; then
    local context=$(kubectl config current-context 2>/dev/null || echo "")
    case "$context" in
      *dev*)
        echo "dev"
        return
        ;;
      *prod*)
        echo "prod"
        return
        ;;
      *local*|kind-*)
        echo "local"
        return
        ;;
    esac
  fi

  # Par défaut
  echo "dev"
}

# =============================================================================
# Parse des arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--env)
      ENVIRONMENT="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -t|--timeout)
      GLOBAL_TIMEOUT="$2"
      shift 2
      ;;
    -w|--wait-healthy)
      WAIT_HEALTHY=1
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      log_error "Option inconnue: $1"
      show_help
      ;;
  esac
done

# Appliquer le timeout global si défini
if [[ -n "$GLOBAL_TIMEOUT" ]]; then
  TIMEOUT_APPSETS=$((GLOBAL_TIMEOUT / 4))
  TIMEOUT_APPS_GENERATION=$((GLOBAL_TIMEOUT / 10))
  TIMEOUT_APPS_SYNC=$((GLOBAL_TIMEOUT / 2))
  TIMEOUT_API_LB=$((GLOBAL_TIMEOUT / 10))
fi

# Détecter l'environnement
ENVIRONMENT=$(detect_environment)

# =============================================================================
# Début du déploiement
# =============================================================================

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Déploiement des ApplicationSets${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
log_info "Environnement: ${BOLD}$ENVIRONMENT${RESET}"
log_info "Namespace ArgoCD: ${BOLD}$ARGOCD_NAMESPACE${RESET}"
log_info "Kubeconfig: ${BOLD}${KUBECONFIG:-~/.kube/config}${RESET}"
echo ""

# Validation
validate_prerequisites

# =============================================================================
# Configuration SOPS/KSOPS pour le chiffrement des secrets
# =============================================================================

setup_sops_secret() {
  log_info "Configuration du secret SOPS pour KSOPS..."

  # Chemin vers les clés AGE (relatif au répertoire racine du projet)
  local project_root="${SCRIPT_DIR}/../.."
  local sops_dir="${project_root}/sops"
  local key_file=""

  # Sélectionner la clé selon l'environnement
  case "$ENVIRONMENT" in
    dev|local)
      key_file="${sops_dir}/age-dev.key"
      ;;
    prod)
      key_file="${sops_dir}/age-prod.key"
      ;;
    *)
      key_file="${sops_dir}/age-dev.key"
      ;;
  esac

  # Vérifier que le fichier de clé existe
  if [[ ! -f "$key_file" ]]; then
    log_warning "Fichier de clé AGE non trouvé: $key_file"
    log_warning "Les secrets SOPS ne pourront pas être déchiffrés par ArgoCD"
    log_warning "Pour générer une clé: age-keygen -o $key_file"
    return 0
  fi

  # Vérifier si le secret existe déjà
  if kubectl get secret sops-age-key -n "$ARGOCD_NAMESPACE" &> /dev/null; then
    log_debug "Secret sops-age-key existe déjà, mise à jour..."
    kubectl delete secret sops-age-key -n "$ARGOCD_NAMESPACE" --ignore-not-found > /dev/null
  fi

  # Créer le secret avec la clé AGE
  if kubectl create secret generic sops-age-key \
    --namespace="$ARGOCD_NAMESPACE" \
    --from-file=keys.txt="$key_file" > /dev/null 2>&1; then
    log_success "Secret sops-age-key créé/mis à jour pour l'environnement $ENVIRONMENT"
  else
    log_error "Échec de la création du secret sops-age-key"
    return 1
  fi
}

# Configurer le secret SOPS
setup_sops_secret

# =============================================================================
# Lecture des feature flags depuis config.yaml
# =============================================================================

CONFIG_FILE="${SCRIPT_DIR}/config/config.yaml"

get_feature() {
  local path="$1"
  local default="${2:-false}"
  local value
  # Ne pas utiliser // car il remplace aussi les valeurs falsy (false, 0)
  value=$(yq -r "$path" "$CONFIG_FILE" 2>/dev/null)
  # Normaliser les valeurs booléennes
  case "$value" in
    true|True|TRUE|yes|Yes|YES|1) echo "true" ;;
    false|False|FALSE|no|No|NO|0) echo "false" ;;
    null|"") echo "$default" ;;
    *) echo "$value" ;;
  esac
}

log_info "Lecture des feature flags depuis config.yaml..."

# Lecture des feature flags
FEAT_METALLB=$(get_feature '.features.metallb.enabled' 'true')
FEAT_KUBEVIP=$(get_feature '.features.kubeVip.enabled' 'true')
FEAT_GATEWAY_API=$(get_feature '.features.gatewayAPI.enabled' 'true')
FEAT_GATEWAY_HTTPROUTE=$(get_feature '.features.gatewayAPI.httpRoute.enabled' 'true')
FEAT_GATEWAY_CONTROLLER=$(get_feature '.features.gatewayAPI.controller.provider' 'istio')
FEAT_CERT_MANAGER=$(get_feature '.features.certManager.enabled' 'true')
FEAT_EXTERNAL_SECRETS=$(get_feature '.features.externalSecrets.enabled' 'true')
FEAT_RELOADER=$(get_feature '.features.reloader.enabled' 'true')
FEAT_EXTERNAL_DNS=$(get_feature '.features.externalDns.enabled' 'true')
FEAT_SERVICE_MESH=$(get_feature '.features.serviceMesh.enabled' 'true')
FEAT_SERVICE_MESH_PROVIDER=$(get_feature '.features.serviceMesh.provider' 'istio')
FEAT_STORAGE=$(get_feature '.features.storage.enabled' 'true')
FEAT_STORAGE_PROVIDER=$(get_feature '.features.storage.provider' 'longhorn')
FEAT_CSI_SNAPSHOTTER=$(get_feature '.features.storage.csiSnapshotter' 'true')
FEAT_DATABASE_OPERATOR=$(get_feature '.features.databaseOperator.enabled' 'true')
FEAT_DATABASE_PROVIDER=$(get_feature '.features.databaseOperator.provider' 'cnpg')
FEAT_MONITORING=$(get_feature '.features.monitoring.enabled' 'true')
FEAT_CILIUM_MONITORING=$(get_feature '.features.cilium.monitoring.enabled' 'true')
FEAT_LOGGING=$(get_feature '.features.logging.enabled' 'true')
FEAT_LOGGING_LOKI=$(get_feature '.features.logging.loki.enabled' 'true')
FEAT_LOGGING_COLLECTOR=$(get_feature '.features.logging.loki.collector' 'alloy')
FEAT_SSO=$(get_feature '.features.sso.enabled' 'true')
FEAT_SSO_PROVIDER=$(get_feature '.features.sso.provider' 'keycloak')
FEAT_OAUTH2_PROXY=$(get_feature '.features.oauth2Proxy.enabled' 'true')
FEAT_NEUVECTOR=$(get_feature '.features.neuvector.enabled' 'false')
FEAT_TRACING=$(get_feature '.features.tracing.enabled' 'false')
FEAT_TRACING_PROVIDER=$(get_feature '.features.tracing.provider' 'jaeger')
FEAT_SERVICEMESH_WAYPOINTS=$(get_feature '.features.serviceMesh.waypoints.enabled' 'false')
FEAT_CILIUM_EGRESS_POLICY=$(get_feature '.features.cilium.egressPolicy.enabled' 'true')
FEAT_CILIUM_INGRESS_POLICY=$(get_feature '.features.cilium.ingressPolicy.enabled' 'true')
FEAT_CILIUM_DEFAULT_DENY_POD_INGRESS=$(get_feature '.features.cilium.defaultDenyPodIngress.enabled' 'true')

log_debug "Feature flags lus:"
log_debug "  metallb: $FEAT_METALLB"
log_debug "  kubeVip: $FEAT_KUBEVIP"
log_debug "  gatewayAPI: $FEAT_GATEWAY_API (httpRoute: $FEAT_GATEWAY_HTTPROUTE, controller: $FEAT_GATEWAY_CONTROLLER)"
log_debug "  certManager: $FEAT_CERT_MANAGER"
log_debug "  externalSecrets: $FEAT_EXTERNAL_SECRETS"
log_debug "  reloader: $FEAT_RELOADER"
log_debug "  externalDns: $FEAT_EXTERNAL_DNS"
log_debug "  serviceMesh: $FEAT_SERVICE_MESH ($FEAT_SERVICE_MESH_PROVIDER)"
log_debug "  storage: $FEAT_STORAGE ($FEAT_STORAGE_PROVIDER)"
log_debug "  csiSnapshotter: $FEAT_CSI_SNAPSHOTTER"
log_debug "  databaseOperator: $FEAT_DATABASE_OPERATOR ($FEAT_DATABASE_PROVIDER)"
log_debug "  monitoring: $FEAT_MONITORING"
log_debug "  cilium.monitoring: $FEAT_CILIUM_MONITORING"
log_debug "  logging: $FEAT_LOGGING (loki: $FEAT_LOGGING_LOKI, collector: $FEAT_LOGGING_COLLECTOR)"
log_debug "  sso: $FEAT_SSO ($FEAT_SSO_PROVIDER)"
log_debug "  oauth2Proxy: $FEAT_OAUTH2_PROXY"
log_debug "  neuvector: $FEAT_NEUVECTOR"
log_debug "  tracing: $FEAT_TRACING ($FEAT_TRACING_PROVIDER)"
log_debug "  serviceMesh.waypoints: $FEAT_SERVICEMESH_WAYPOINTS"
log_debug "  cilium.egressPolicy: $FEAT_CILIUM_EGRESS_POLICY"
log_debug "  cilium.ingressPolicy: $FEAT_CILIUM_INGRESS_POLICY"

# =============================================================================
# Résolution automatique des dépendances
# =============================================================================
# Cette fonction active automatiquement les features requises par d'autres features
# Exemple: Keycloak active automatiquement databaseOperator, externalSecrets, certManager

resolve_dependencies() {
  local changes_made=true
  local iteration=0
  local max_iterations=5  # Éviter les boucles infinies

  log_info "Résolution des dépendances..."

  while [[ "$changes_made" == "true" ]] && [[ $iteration -lt $max_iterations ]]; do
    changes_made=false
    iteration=$((iteration + 1))

    # =========================================================================
    # Keycloak → databaseOperator + externalSecrets + certManager
    # =========================================================================
    if [[ "$FEAT_SSO" == "true" ]] && [[ "$FEAT_SSO_PROVIDER" == "keycloak" ]]; then
      if [[ "$FEAT_DATABASE_OPERATOR" != "true" ]]; then
        log_info "  → Activation de databaseOperator (requis par Keycloak)"
        FEAT_DATABASE_OPERATOR="true"
        FEAT_DATABASE_PROVIDER="${FEAT_DATABASE_PROVIDER:-cnpg}"
        changes_made=true
      fi
      if [[ "$FEAT_EXTERNAL_SECRETS" != "true" ]]; then
        log_info "  → Activation de externalSecrets (requis par Keycloak)"
        FEAT_EXTERNAL_SECRETS="true"
        changes_made=true
      fi
      if [[ "$FEAT_CERT_MANAGER" != "true" ]]; then
        log_info "  → Activation de certManager (requis par Keycloak)"
        FEAT_CERT_MANAGER="true"
        changes_made=true
      fi
    fi

    # =========================================================================
    # istio-gateway → serviceMesh (Istio)
    # =========================================================================
    if [[ "$FEAT_GATEWAY_CONTROLLER" == "istio" ]]; then
      if [[ "$FEAT_SERVICE_MESH" != "true" ]]; then
        log_info "  → Activation de serviceMesh (requis par istio-gateway)"
        FEAT_SERVICE_MESH="true"
        FEAT_SERVICE_MESH_PROVIDER="istio"
        changes_made=true
      elif [[ "$FEAT_SERVICE_MESH_PROVIDER" != "istio" ]]; then
        log_warning "  → Changement serviceMesh.provider vers 'istio' (requis par istio-gateway)"
        FEAT_SERVICE_MESH_PROVIDER="istio"
        changes_made=true
      fi
    fi

    # =========================================================================
    # oauth2-proxy integration mode
    # =========================================================================
    # - HTTPRoute + Istio Gateway → ext_authz (AuthorizationPolicy)
    # - APISIX CRDs → forward-auth plugin
    if [[ "$FEAT_OAUTH2_PROXY" == "true" ]]; then
      if [[ "$FEAT_GATEWAY_API_HTTPROUTE" == "true" ]]; then
        log_info "  → OAuth2-Proxy: mode ext_authz (AuthorizationPolicy Istio)"
      elif [[ "$FEAT_GATEWAY_API_PROVIDER" == "apisix" ]]; then
        log_info "  → OAuth2-Proxy: mode forward-auth (APISIX plugin)"
      fi
    fi

    # =========================================================================
    # cilium → monitoring
    # =========================================================================
    if [[ "$FEAT_CILIUM_MONITORING" == "true" ]]; then
      if [[ "$FEAT_MONITORING" != "true" ]]; then
        log_info "  → Activation de monitoring (requis par cilium)"
        FEAT_MONITORING="true"
        changes_made=true
      fi
    fi

    # =========================================================================
    # longhorn/rook → csiSnapshotter (recommandé)
    # =========================================================================
    if [[ "$FEAT_STORAGE" == "true" ]]; then
      if [[ "$FEAT_STORAGE_PROVIDER" == "longhorn" ]] || [[ "$FEAT_STORAGE_PROVIDER" == "rook" ]]; then
        if [[ "$FEAT_CSI_SNAPSHOTTER" != "true" ]]; then
          log_info "  → Activation de csiSnapshotter (recommandé pour $FEAT_STORAGE_PROVIDER)"
          FEAT_CSI_SNAPSHOTTER="true"
          changes_made=true
        fi
      fi
    fi

    # =========================================================================
    # gatewayAPI CRDs → requis si un controller Gateway API est configuré
    # =========================================================================
    if [[ "$FEAT_GATEWAY_CONTROLLER" == "istio" ]] || \
       [[ "$FEAT_GATEWAY_CONTROLLER" == "nginx-gateway-fabric" ]] || \
       [[ "$FEAT_GATEWAY_CONTROLLER" == "envoy-gateway" ]] || \
       [[ "$FEAT_GATEWAY_CONTROLLER" == "apisix" ]] || \
       [[ "$FEAT_GATEWAY_CONTROLLER" == "traefik" ]]; then
      if [[ "$FEAT_GATEWAY_API" != "true" ]]; then
        log_info "  → Activation de gatewayAPI (requis par $FEAT_GATEWAY_CONTROLLER)"
        FEAT_GATEWAY_API="true"
        changes_made=true
      fi
    fi

    # =========================================================================
    # tracing waypoints → serviceMesh (Istio) + gatewayAPI
    # =========================================================================
    # Waypoint proxies require Istio Ambient mode for L7 tracing
    if [[ "$FEAT_SERVICEMESH_WAYPOINTS" == "true" ]]; then
      if [[ "$FEAT_SERVICE_MESH" != "true" ]]; then
        log_info "  → Activation de serviceMesh (requis par tracing waypoints)"
        FEAT_SERVICE_MESH="true"
        FEAT_SERVICE_MESH_PROVIDER="istio"
        changes_made=true
      elif [[ "$FEAT_SERVICE_MESH_PROVIDER" != "istio" ]]; then
        log_warning "  → Changement serviceMesh.provider vers 'istio' (requis par tracing waypoints)"
        FEAT_SERVICE_MESH_PROVIDER="istio"
        changes_made=true
      fi
      # Waypoints use Gateway API
      if [[ "$FEAT_GATEWAY_API" != "true" ]]; then
        log_info "  → Activation de gatewayAPI (requis par tracing waypoints)"
        FEAT_GATEWAY_API="true"
        changes_made=true
      fi
    fi

  done

  if [[ $iteration -ge $max_iterations ]]; then
    log_warning "Résolution des dépendances: nombre max d'itérations atteint"
  fi

  log_success "Dépendances résolues (${iteration} itération(s))"
}

# =============================================================================
# Validation finale des dépendances (erreurs critiques)
# =============================================================================
# Vérifie les incohérences qui ne peuvent pas être résolues automatiquement

validate_dependencies() {
  local errors=0

  # Vérifier les conflits de providers
  if [[ "$FEAT_SERVICE_MESH" == "true" ]] && [[ "$FEAT_SERVICE_MESH_PROVIDER" != "istio" ]]; then
    if [[ "$FEAT_GATEWAY_CONTROLLER" == "istio" ]]; then
      log_error "Conflit: gatewayAPI.controller.provider=istio mais serviceMesh.provider=$FEAT_SERVICE_MESH_PROVIDER"
      errors=$((errors + 1))
    fi
  fi

  # Vérifier que le provider de database operator est supporté
  if [[ "$FEAT_DATABASE_OPERATOR" == "true" ]]; then
    case "$FEAT_DATABASE_PROVIDER" in
      cnpg) ;;  # OK
      *)
        log_error "Database provider '$FEAT_DATABASE_PROVIDER' non supporté (seul 'cnpg' est disponible)"
        errors=$((errors + 1))
        ;;
    esac
  fi

  # Vérifier que le storage provider est supporté
  if [[ "$FEAT_STORAGE" == "true" ]]; then
    case "$FEAT_STORAGE_PROVIDER" in
      longhorn|rook) ;;  # OK
      *)
        log_error "Storage provider '$FEAT_STORAGE_PROVIDER' non supporté (longhorn, rook)"
        errors=$((errors + 1))
        ;;
    esac
  fi

  # Vérifier que le gateway controller est supporté
  case "$FEAT_GATEWAY_CONTROLLER" in
    istio|nginx-gateway-fabric|nginx-gwf|envoy-gateway|apisix|traefik|nginx|"") ;;  # OK
    *)
      log_error "Gateway controller '$FEAT_GATEWAY_CONTROLLER' non supporté"
      errors=$((errors + 1))
      ;;
  esac

  # Avertir si APISIX + HTTPRoute (sous-optimal, préférer les CRDs natifs APISIX)
  if [[ "$FEAT_GATEWAY_API" == "true" ]] && [[ "$FEAT_GATEWAY_HTTPROUTE" == "true" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" == "apisix" ]]; then
    log_warning "APISIX avec HTTPRoute activé - pour de meilleures performances (HTTPS backend natif),"
    log_warning "  désactivez httpRoute.enabled et utilisez les CRDs natifs ApisixRoute/ApisixUpstream"
  fi

  if [[ $errors -gt 0 ]]; then
    log_error "$errors erreur(s) de configuration détectée(s)"
    exit 1
  fi

  log_success "Validation des dépendances OK"
}

# Appeler dans cet ordre
resolve_dependencies
validate_dependencies

# =============================================================================
# Construction dynamique de la liste des ApplicationSets
# =============================================================================

log_info "Construction de la liste des ApplicationSets..."

APPLICATIONSETS=()

# Wave 10: Load Balancer
[[ "$FEAT_METALLB" == "true" ]] && APPLICATIONSETS+=("apps/metallb/applicationset.yaml")

# Wave 15: API HA + Gateway API CRDs
[[ "$FEAT_KUBEVIP" == "true" ]] && APPLICATIONSETS+=("apps/kube-vip/applicationset.yaml")
# gateway-api-controller installe les CRDs Gateway API, sauf si apisix ou traefik est le provider
# (apisix et traefik incluent leurs propres CRDs Gateway API dans leur chart Helm)
[[ "$FEAT_GATEWAY_API" == "true" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" != "apisix" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" != "traefik" ]] && APPLICATIONSETS+=("apps/gateway-api-controller/applicationset.yaml")

# Wave 20: Certificates
[[ "$FEAT_CERT_MANAGER" == "true" ]] && APPLICATIONSETS+=("apps/cert-manager/applicationset.yaml")

# Wave 25: Secrets Management
[[ "$FEAT_EXTERNAL_SECRETS" == "true" ]] && APPLICATIONSETS+=("apps/external-secrets/applicationset.yaml")

# Wave 25: Configuration Reload (auto-reload pods on ConfigMap/Secret changes)
[[ "$FEAT_RELOADER" == "true" ]] && APPLICATIONSETS+=("apps/reloader/applicationset.yaml")

# Wave 30: DNS
[[ "$FEAT_EXTERNAL_DNS" == "true" ]] && APPLICATIONSETS+=("apps/external-dns/applicationset.yaml")

# Wave 40-42: Service Mesh + Gateway Controller
if [[ "$FEAT_SERVICE_MESH" == "true" ]] && [[ "$FEAT_SERVICE_MESH_PROVIDER" == "istio" ]]; then
  APPLICATIONSETS+=("apps/istio/applicationset.yaml")
fi

# Gateway Controller (basé sur gatewayAPI.controller.provider)
if [[ -n "$FEAT_GATEWAY_CONTROLLER" ]]; then
  case "$FEAT_GATEWAY_CONTROLLER" in
    istio)
      # istio-gateway nécessite le service mesh Istio
      if [[ "$FEAT_SERVICE_MESH" == "true" ]] && [[ "$FEAT_SERVICE_MESH_PROVIDER" == "istio" ]]; then
        APPLICATIONSETS+=("apps/istio-gateway/applicationset.yaml")
      else
        log_warning "gatewayAPI.controller.provider=istio nécessite serviceMesh.enabled=true"
      fi
      ;;
    nginx-gateway-fabric|nginx-gwf)
      APPLICATIONSETS+=("apps/nginx-gateway-fabric/applicationset.yaml")
      ;;
    envoy-gateway)
      APPLICATIONSETS+=("apps/envoy-gateway/applicationset.yaml")
      ;;
    apisix)
      APPLICATIONSETS+=("apps/apisix/applicationset.yaml")
      ;;
    traefik)
      APPLICATIONSETS+=("apps/traefik/applicationset.yaml")
      ;;
    nginx)
      # Legacy Ingress NGINX (pas Gateway API natif)
      APPLICATIONSETS+=("apps/ingress-nginx/applicationset.yaml")
      ;;
  esac
fi

# Wave 50: GitOps Controller (toujours déployé)
APPLICATIONSETS+=("apps/argocd/applicationset.yaml")

# Wave 55-60: Storage
if [[ "$FEAT_STORAGE" == "true" ]]; then
  [[ "$FEAT_CSI_SNAPSHOTTER" == "true" ]] && APPLICATIONSETS+=("apps/csi-external-snapshotter/applicationset.yaml")

  case "$FEAT_STORAGE_PROVIDER" in
    longhorn)
      APPLICATIONSETS+=("apps/longhorn/applicationset.yaml")
      ;;
    rook)
      APPLICATIONSETS+=("apps/rook/applicationset.yaml")
      ;;
  esac
fi

# Wave 65: Database Operator
if [[ "$FEAT_DATABASE_OPERATOR" == "true" ]]; then
  case "$FEAT_DATABASE_PROVIDER" in
    cnpg)
      APPLICATIONSETS+=("apps/cnpg-operator/applicationset.yaml")
      ;;
  esac
fi

# Wave 73-74: Logging (Loki + collector)
if [[ "$FEAT_LOGGING" == "true" ]] && [[ "$FEAT_LOGGING_LOKI" == "true" ]]; then
  APPLICATIONSETS+=("apps/loki/applicationset.yaml")
  case "$FEAT_LOGGING_COLLECTOR" in
    alloy)
      APPLICATIONSETS+=("apps/alloy/applicationset.yaml")
      ;;
  esac
fi

# Wave 75-76: Monitoring
if [[ "$FEAT_MONITORING" == "true" ]]; then
  APPLICATIONSETS+=("apps/prometheus-stack/applicationset.yaml")
fi

# Cilium (CNI installé par RKE2, cette app ajoute monitoring + network policies)
if [[ "$FEAT_CILIUM_MONITORING" == "true" ]] && [[ "$FEAT_MONITORING" == "true" ]]; then
  APPLICATIONSETS+=("apps/cilium/applicationset.yaml")
fi

# Wave 77: Distributed Tracing
if [[ "$FEAT_TRACING" == "true" ]]; then
  case "$FEAT_TRACING_PROVIDER" in
    jaeger)
      APPLICATIONSETS+=("apps/jaeger/applicationset.yaml")
      ;;
    tempo)
      APPLICATIONSETS+=("apps/tempo/applicationset.yaml")
      ;;
  esac
fi

# Wave 80-81: SSO + OAuth2-Proxy
if [[ "$FEAT_SSO" == "true" ]]; then
  case "$FEAT_SSO_PROVIDER" in
    keycloak)
      APPLICATIONSETS+=("apps/keycloak/applicationset.yaml")
      ;;
    external)
      log_info "SSO avec IdP externe - Keycloak non déployé"
      ;;
  esac
fi

# OAuth2-Proxy (indépendant du SSO - peut utiliser IdP externe)
[[ "$FEAT_OAUTH2_PROXY" == "true" ]] && APPLICATIONSETS+=("apps/oauth2-proxy/applicationset.yaml")

# NeuVector (container security platform)
[[ "$FEAT_NEUVECTOR" == "true" ]] && APPLICATIONSETS+=("apps/neuvector/applicationset.yaml")

# Calculer le nombre d'applications attendues
# En environnement dev/local, chaque ApplicationSet génère 1 Application
# En environnement prod, certains ApplicationSets peuvent générer plusieurs Applications (HA)
EXPECTED_APPS_COUNT=${#APPLICATIONSETS[@]}
log_debug "Nombre d'Applications attendues: $EXPECTED_APPS_COUNT"

# Afficher la liste finale
log_info "ApplicationSets à déployer (${#APPLICATIONSETS[@]}):"
for appset in "${APPLICATIONSETS[@]}"; do
  log_debug "  - $appset"
done

# Vérifier que tous les fichiers existent
log_info "Vérification des fichiers ApplicationSets..."
missing_files=()
for appset in "${APPLICATIONSETS[@]}"; do
  appset_path="${SCRIPT_DIR}/${appset}"
  if [[ ! -f "$appset_path" ]]; then
    missing_files+=("$appset")
  fi
done

if [[ ${#missing_files[@]} -gt 0 ]]; then
  log_error "Fichiers manquants:"
  for file in "${missing_files[@]}"; do
    echo "  - $file"
  done
  exit 1
fi
log_success "Tous les fichiers ApplicationSets sont présents"

# =============================================================================
# Pré-déploiement des CiliumNetworkPolicies (bootstrap)
# =============================================================================
# Ordre d'application:
# 1. CiliumClusterwideNetworkPolicy (default-deny-external-egress)
#    → Autorise le trafic interne (cluster, kube-apiserver, DNS) pour tous les pods
#    → Bloque l'egress externe (world) par défaut
# 2. CiliumNetworkPolicy ArgoCD
#    → Ajoute l'accès externe (GitHub, Helm registries) pour ArgoCD uniquement
#
# Sans ces policies pré-appliquées, ArgoCD ne peut pas accéder à GitHub pour
# récupérer sa propre configuration (chicken-and-egg problem).

apply_bootstrap_network_policies() {
  if [[ "$FEAT_CILIUM_EGRESS_POLICY" != "true" ]] && [[ "$FEAT_CILIUM_INGRESS_POLICY" != "true" ]]; then
    log_debug "Cilium policies désactivées, pas de pré-déploiement nécessaire"
    return 0
  fi

  log_info "Pré-déploiement des CiliumNetworkPolicies pour bootstrap..."

  # 1. Egress clusterwide policy - bloque le trafic externe, autorise le trafic interne
  if [[ "$FEAT_CILIUM_EGRESS_POLICY" == "true" ]]; then
    local egress_policy="${SCRIPT_DIR}/apps/cilium/resources/default-deny-external-egress.yaml"
    if [[ -f "$egress_policy" ]]; then
      if kubectl apply -f "$egress_policy" > /dev/null 2>&1; then
        log_success "CiliumClusterwideNetworkPolicy egress appliquée (trafic interne autorisé)"
      else
        log_warning "Impossible d'appliquer la CiliumClusterwideNetworkPolicy egress"
      fi
    else
      log_debug "Pas de egress policy trouvée: $egress_policy"
    fi
  fi

  # 2. Host ingress policy - protège les nœuds (SSH, API, HTTP/HTTPS autorisés)
  if [[ "$FEAT_CILIUM_INGRESS_POLICY" == "true" ]]; then
    local ingress_policy="${SCRIPT_DIR}/apps/cilium/resources/default-deny-host-ingress.yaml"
    if [[ -f "$ingress_policy" ]]; then
      if kubectl apply -f "$ingress_policy" > /dev/null 2>&1; then
        log_success "CiliumClusterwideNetworkPolicy host ingress appliquée (SSH, API, HTTP/HTTPS)"
      else
        log_warning "Impossible d'appliquer la CiliumClusterwideNetworkPolicy host ingress"
      fi
    else
      log_debug "Pas de host ingress policy trouvée: $ingress_policy"
    fi
  fi

  # 3. ArgoCD egress policy - ajoute l'accès externe (GitHub, Helm)
  if [[ "$FEAT_CILIUM_EGRESS_POLICY" == "true" ]]; then
    local argocd_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-egress-policy.yaml"
    if [[ -f "$argocd_policy" ]]; then
      if kubectl apply -f "$argocd_policy" > /dev/null 2>&1; then
        log_success "CiliumNetworkPolicy ArgoCD egress appliquée (accès GitHub/Helm)"
      else
        log_warning "Impossible d'appliquer la CiliumNetworkPolicy ArgoCD egress"
      fi
    else
      log_debug "Pas de egress policy ArgoCD trouvée: $argocd_policy"
    fi
  fi

  # 4. ArgoCD ingress policy - permet la communication interne ArgoCD
  # CRITIQUE: Doit être déployé AVANT default-deny-pod-ingress pour permettre
  # la communication controller <-> repo-server (port 8081)
  # Policy interne (pod-to-pod dans argo-cd namespace)
  if [[ "$FEAT_CILIUM_DEFAULT_DENY_POD_INGRESS" == "true" ]]; then
    local argocd_internal_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy.yaml"
    if [[ -f "$argocd_internal_policy" ]]; then
      if kubectl apply -f "$argocd_internal_policy" > /dev/null 2>&1; then
        log_success "CiliumNetworkPolicy ArgoCD ingress appliquée (internal)"
      else
        log_warning "Impossible d'appliquer la CiliumNetworkPolicy ArgoCD ingress (internal)"
      fi
    fi
  fi

  # Policy gateway (external access) - séparée par provider
  if [[ "$FEAT_CILIUM_INGRESS_POLICY" == "true" ]]; then
    local argocd_ingress_policy=""
    case "$FEAT_GATEWAY_CONTROLLER" in
      istio)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy-istio.yaml"
        ;;
      apisix)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy-apisix.yaml"
        ;;
      traefik)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy-traefik.yaml"
        ;;
      nginx-gateway-fabric|nginx-gwf)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy-nginx-gwf.yaml"
        ;;
      envoy-gateway)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy-envoy-gateway.yaml"
        ;;
      *)
        log_warning "Provider Gateway inconnu: $FEAT_GATEWAY_CONTROLLER - pas de policy gateway ArgoCD"
        ;;
    esac
    if [[ -n "$argocd_ingress_policy" && -f "$argocd_ingress_policy" ]]; then
      if kubectl apply -f "$argocd_ingress_policy" > /dev/null 2>&1; then
        log_success "CiliumNetworkPolicy ArgoCD ingress appliquée ($FEAT_GATEWAY_CONTROLLER)"
      else
        log_warning "Impossible d'appliquer la CiliumNetworkPolicy ArgoCD ingress ($FEAT_GATEWAY_CONTROLLER)"
      fi
    fi
  fi

  # Wait for Cilium to propagate policies to endpoints
  log_info "Attente de la propagation des policies Cilium (10s)..."
  sleep 10
}

apply_bootstrap_network_policies

# =============================================================================
# Attente du repo-server (requis AVANT déploiement des ApplicationSets)
# =============================================================================
# Les ApplicationSets utilisent un Git generator qui nécessite le repo-server.
# Si on déploie les ApplicationSets avant que le repo-server soit prêt,
# ils échouent et attendent 3 minutes (requeueAfter) pour réessayer.

echo ""
check_repo_server_ready() {
  # Check pod is Ready
  local ready
  ready=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$ready" != "True" ]]; then
    return 1
  fi

  # Verify the service endpoint is registered
  local endpoints
  endpoints=$(kubectl get endpoints -n "$ARGOCD_NAMESPACE" argocd-repo-server -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  if [[ -n "$endpoints" ]]; then
    printf "\n"
    log_success "ArgoCD repo-server est prêt (endpoints: $endpoints)"
    # Wait for gRPC service to fully initialize after pod is Ready
    log_info "Attente initialisation du service gRPC repo-server (10s)..."
    sleep 10
    return 0
  fi

  return 1
}

wait_for_condition \
  "Attente du repo-server ArgoCD..." \
  "$TIMEOUT_APPSETS" \
  check_repo_server_ready || {
    log_warning "repo-server non prêt - les ApplicationSets devront attendre 3min pour réconcilier"
  }

# =============================================================================
# Déploiement des ApplicationSets (en parallèle)
# =============================================================================

echo ""
log_info "Déploiement des ApplicationSets..."

# Créer un fichier temporaire avec tous les ApplicationSets
TEMP_MANIFEST=$(mktemp)
trap "rm -f $TEMP_MANIFEST" EXIT

for appset in "${APPLICATIONSETS[@]}"; do
  appset_path="${SCRIPT_DIR}/${appset}"
  cat "$appset_path" >> "$TEMP_MANIFEST"
  echo "---" >> "$TEMP_MANIFEST"
done

# Appliquer tous les ApplicationSets en une seule commande
if [[ $VERBOSE -eq 1 ]]; then
  kubectl apply -f "$TEMP_MANIFEST"
else
  kubectl apply -f "$TEMP_MANIFEST" > /dev/null
fi

log_success "ApplicationSets déployés"

# =============================================================================
# Attente de la création des ApplicationSets
# =============================================================================

echo ""
check_appsets_created() {
  local current=$(kubectl get applicationset -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
  local expected=${#APPLICATIONSETS[@]}

  if [[ $current -eq $expected ]]; then
    printf "\n"
    log_success "Tous les ApplicationSets sont créés ($current/$expected)"
    return 0
  fi

  log_debug "ApplicationSets: $current/$expected"
  return 1
}

wait_for_condition \
  "Attente de la création des ApplicationSets..." \
  "$TIMEOUT_APPSETS" \
  check_appsets_created

# =============================================================================
# Attente de la génération des Applications
# =============================================================================

echo ""
log_info "Attente de la génération des Applications (attendu: $EXPECTED_APPS_COUNT)..."
apps_gen_elapsed=0
apps_gen_interval=5

while true; do
  current_apps=$(kubectl get application -A --no-headers 2>/dev/null | wc -l)

  if [[ $current_apps -ge $EXPECTED_APPS_COUNT ]]; then
    # Afficher la barre de progression finale à 100%
    printf "\r  Applications: [%-50s] %d%% (%d/%d)\n" \
      "$(printf '#%.0s' $(seq 1 50))" \
      100 "$current_apps" "$EXPECTED_APPS_COUNT"
    log_success "Toutes les Applications générées: $current_apps/$EXPECTED_APPS_COUNT"
    break
  fi

  # Timeout
  if [[ $apps_gen_elapsed -ge $TIMEOUT_APPS_GENERATION ]]; then
    printf "\n"
    log_warning "Timeout après ${TIMEOUT_APPS_GENERATION}s: $current_apps/$EXPECTED_APPS_COUNT Applications générées"
    log_info "Vérifiez les logs du ApplicationSet Controller:"
    echo "  kubectl logs -n $ARGOCD_NAMESPACE -l app.kubernetes.io/name=argocd-applicationset-controller"
    break
  fi

  # Barre de progression
  progress=$((current_apps * 100 / EXPECTED_APPS_COUNT))
  printf "\r  Applications: [%-50s] %d%% (%d/%d)" \
    "$(printf '#%.0s' $(seq 1 $((progress / 2))))" \
    "$progress" "$current_apps" "$EXPECTED_APPS_COUNT"

  sleep $apps_gen_interval
  apps_gen_elapsed=$((apps_gen_elapsed + apps_gen_interval))
done

# =============================================================================
# Attente de la synchronisation des Applications
# =============================================================================

echo ""
if [[ $WAIT_HEALTHY -eq 1 ]]; then
  log_info "Attente de la synchronisation et santé des Applications (sans timeout)..."
else
  log_info "Attente de la synchronisation et santé des Applications (timeout: ${TIMEOUT_APPS_SYNC}s)..."
fi
sync_elapsed=0
sync_interval=5

while true; do
  # Récupérer toutes les applications en une seule requête
  APPS_JSON=$(kubectl get application -A -o json 2>/dev/null)
  TOTAL_APPS=$(echo "$APPS_JSON" | jq -r '.items | length')

  if [[ $TOTAL_APPS -eq 0 ]]; then
    log_debug "Aucune application trouvée, attente..."
    sleep $sync_interval
    sync_elapsed=$((sync_elapsed + sync_interval))
    continue
  fi

  # Parser le JSON une seule fois
  SYNCED=$(echo "$APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="Synced")] | length')
  HEALTHY=$(echo "$APPS_JSON" | jq -r '[.items[] | select(.status.health.status=="Healthy")] | length')
  SYNCED_AND_HEALTHY=$(echo "$APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')

  # Affichage de l'état - utiliser le nombre attendu pour la progression
  target_apps=$EXPECTED_APPS_COUNT
  [[ $TOTAL_APPS -gt $target_apps ]] && target_apps=$TOTAL_APPS
  progress=$((SYNCED_AND_HEALTHY * 100 / target_apps))

  if [[ $WAIT_HEALTHY -eq 1 ]]; then
    printf "\r  État: [%-50s] %d%% (%d/%d apps Synced + Healthy, %ds)" \
      "$(printf '#%.0s' $(seq 1 $((progress / 2))))" \
      "$progress" "$SYNCED_AND_HEALTHY" "$target_apps" "$sync_elapsed"
  else
    printf "\r  État: [%-50s] %d%% (%d/%d apps Synced + Healthy)" \
      "$(printf '#%.0s' $(seq 1 $((progress / 2))))" \
      "$progress" "$SYNCED_AND_HEALTHY" "$target_apps"
  fi

  log_debug "Synced: $SYNCED, Healthy: $HEALTHY, Total: $TOTAL_APPS, Expected: $EXPECTED_APPS_COUNT"

  # Condition de succès: toutes les apps attendues sont synced et healthy
  if [[ $SYNCED_AND_HEALTHY -ge $EXPECTED_APPS_COUNT ]] && [[ $TOTAL_APPS -ge $EXPECTED_APPS_COUNT ]]; then
    # Afficher la barre de progression finale à 100%
    if [[ $WAIT_HEALTHY -eq 1 ]]; then
      printf "\r  État: [%-50s] %d%% (%d/%d apps Synced + Healthy, %ds)\n" \
        "$(printf '#%.0s' $(seq 1 50))" \
        100 "$SYNCED_AND_HEALTHY" "$EXPECTED_APPS_COUNT" "$sync_elapsed"
    else
      printf "\r  État: [%-50s] %d%% (%d/%d apps Synced + Healthy)\n" \
        "$(printf '#%.0s' $(seq 1 50))" \
        100 "$SYNCED_AND_HEALTHY" "$EXPECTED_APPS_COUNT"
    fi
    log_success "Toutes les applications sont Synced + Healthy! ($SYNCED_AND_HEALTHY/$EXPECTED_APPS_COUNT)"
    break
  fi

  # Timeout (sauf si --wait-healthy)
  if [[ $WAIT_HEALTHY -eq 0 ]] && [[ $sync_elapsed -ge $TIMEOUT_APPS_SYNC ]]; then
    printf "\n"
    log_warning "Timeout après ${TIMEOUT_APPS_SYNC}s: $SYNCED_AND_HEALTHY/$EXPECTED_APPS_COUNT apps Synced + Healthy"
    echo ""
    log_warning "Applications avec problèmes:"
    echo "$APPS_JSON" | jq -r '.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy") | "  - \(.metadata.name): Sync=\(.status.sync.status // "Unknown") Health=\(.status.health.status // "Unknown")"'
    break
  fi

  sleep $sync_interval
  sync_elapsed=$((sync_elapsed + sync_interval))
done

# =============================================================================
# Mise à jour du kubeconfig avec l'IP du LoadBalancer
# =============================================================================

echo ""
echo ""
log_info "Mise à jour du kubeconfig avec l'IP du LoadBalancer..."

# Récupérer l'IP VIP depuis le DaemonSet kube-vip
API_VIP=""
check_kube_vip() {
  # Récupérer l'IP VIP depuis l'env var 'address' du DaemonSet kube-vip
  API_VIP=$(kubectl get daemonset kube-vip -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="address")].value}' 2>/dev/null || echo "")

  if [[ -z "$API_VIP" ]]; then
    log_debug "DaemonSet kube-vip non trouvé ou VIP non configurée"
    return 1
  fi

  # Vérifier si la VIP répond (test de connectivité TCP sur port 6443)
  if timeout 2 bash -c "echo > /dev/tcp/${API_VIP}/6443" 2>/dev/null; then
    printf "\n"
    log_success "VIP Kube-VIP active: $API_VIP"
    return 0
  fi

  log_debug "VIP configurée ($API_VIP) mais pas encore active..."
  return 1
}

if wait_for_condition \
  "Attente de la VIP Kube-VIP..." \
  "$TIMEOUT_API_LB" \
  check_kube_vip; then

  # Déterminer le chemin du kubeconfig
  if [[ -n "$KUBECONFIG" ]]; then
    KUBECONFIG_PATH="$KUBECONFIG"
  else
    # Utiliser le chemin relatif basé sur l'environnement
    KUBECONFIG_PATH="${SCRIPT_DIR}/../../vagrant/.kube/config-${ENVIRONMENT}"

    # Fallback vers config par défaut si pas trouvé
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
      KUBECONFIG_PATH="$HOME/.kube/config"
    fi
  fi

  if [[ -f "$KUBECONFIG_PATH" ]]; then
    # Sauvegarder l'ancien kubeconfig
    backup_path="${KUBECONFIG_PATH}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$KUBECONFIG_PATH" "$backup_path"
    log_debug "Backup créé: $backup_path"

    # Récupérer l'ancienne IP du serveur
    OLD_SERVER=$(grep "server:" "$KUBECONFIG_PATH" | head -1 | awk '{print $2}')
    NEW_SERVER="https://${API_VIP}:6443"

    # Remplacer l'ancienne IP par la nouvelle
    sed -i "s|$OLD_SERVER|$NEW_SERVER|g" "$KUBECONFIG_PATH"

    echo ""
    log_success "Kubeconfig mis à jour:"
    echo "  Ancien serveur: $OLD_SERVER"
    echo "  Nouveau serveur: $NEW_SERVER (Kube-VIP VIP)"
    echo "  Fichier: $KUBECONFIG_PATH"
    echo "  Backup: $backup_path"
    echo ""
    log_info "Vous pouvez maintenant accéder à l'API via la VIP Kube-VIP:"
    echo "  export KUBECONFIG=$KUBECONFIG_PATH"
    echo "  kubectl get nodes"
  else
    log_warning "Kubeconfig non trouvé: $KUBECONFIG_PATH"
    log_info "Vous pouvez créer un nouveau kubeconfig avec l'IP VIP $API_VIP"
  fi
else
  log_warning "La VIP Kube-VIP n'est pas accessible"
  log_info "Le kubeconfig ne sera pas mis à jour."
  log_info "Vérifiez que le DaemonSet kube-vip est déployé et fonctionne correctement."
fi

# =============================================================================
# Patch des ingress sans ingressClassName
# =============================================================================

echo ""
log_info "Vérification des ingress sans IngressClass..."

# Lire la configuration globale pour connaître la classe d'ingress préférée
CONFIG_FILE="${SCRIPT_DIR}/config/config.yaml"
INGRESS_ENABLED=$(yq -r '.features.ingress.enabled' "$CONFIG_FILE")
INGRESS_CLASS=$(yq -r '.features.ingress.class' "$CONFIG_FILE")

# Si l'ingress est désactivé ou si la classe n'est pas définie, on ne fait rien
if [[ "$INGRESS_ENABLED" == "false" ]]; then
  log_debug "Ingress désactivé dans la configuration, pas de patch automatique."
elif [[ -z "$INGRESS_CLASS" ]]; then
  log_debug "Pas de classe d'ingress définie dans la configuration."
else
  log_info "Classe d'ingress configurée: $INGRESS_CLASS"

  # Trouver tous les ingress sans ingressClassName
  INGRESS_TO_PATCH=$(kubectl get ingress -A -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.ingressClassName == null) | "\(.metadata.namespace)/\(.metadata.name)"')

  if [[ -n "$INGRESS_TO_PATCH" ]]; then
    echo "$INGRESS_TO_PATCH" | while IFS='/' read -r namespace name; do
      log_info "Patch de l'ingress $namespace/$name avec ingressClassName=$INGRESS_CLASS"
      kubectl patch ingress "$name" -n "$namespace" --type merge \
        -p "{\"spec\":{\"ingressClassName\":\"$INGRESS_CLASS\"}}" 2>/dev/null || \
        log_warning "Impossible de patcher $namespace/$name"
    done
    log_success "Ingress patchés avec succès"
  else
    log_debug "Tous les ingress ont déjà un ingressClassName"
  fi
fi

# =============================================================================
# État final
# =============================================================================

echo ""
echo ""

# Vérifier l'état final des applications
FINAL_APPS_JSON=$(kubectl get application -A -o json 2>/dev/null)
FINAL_TOTAL=$(echo "$FINAL_APPS_JSON" | jq -r '.items | length')
FINAL_SYNCED_HEALTHY=$(echo "$FINAL_APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')
FINAL_SYNCED=$(echo "$FINAL_APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="Synced")] | length')
FINAL_OUTOFSYNC_AUTOSYNC=$(echo "$FINAL_APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="OutOfSync" and (.spec.syncPolicy.automated.prune==true or .spec.syncPolicy.automated.selfHeal==true))] | length')

# Message de fin en fonction de l'état
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if [[ $FINAL_SYNCED_HEALTHY -ge $EXPECTED_APPS_COUNT ]] && [[ $FINAL_TOTAL -ge $EXPECTED_APPS_COUNT ]]; then
  echo -e "${GREEN}✅ Installation terminée!${RESET}"
  echo -e "${GREEN}   ($FINAL_SYNCED_HEALTHY/$EXPECTED_APPS_COUNT apps Synced + Healthy)${RESET}"
elif [[ $FINAL_OUTOFSYNC_AUTOSYNC -gt 0 ]]; then
  echo -e "${YELLOW}⏳ Installation terminée - Synchronisation automatique en cours...${RESET}"
  echo -e "${YELLOW}   ($FINAL_OUTOFSYNC_AUTOSYNC app(s) OutOfSync avec auto-sync se synchroniseront automatiquement)${RESET}"
  OUTOFSYNC_APPS_LIST=$(echo "$FINAL_APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="OutOfSync" and (.spec.syncPolicy.automated.prune==true or .spec.syncPolicy.automated.selfHeal==true)) | .metadata.name] | join(", ")')
  echo -e "${YELLOW}   Apps: $OUTOFSYNC_APPS_LIST${RESET}"
elif [[ $FINAL_SYNCED -eq $FINAL_TOTAL ]] && [[ $FINAL_TOTAL -gt 0 ]]; then
  echo -e "${YELLOW}⚠️  Installation terminée avec avertissements${RESET}"
  echo -e "${YELLOW}   ($FINAL_SYNCED/$EXPECTED_APPS_COUNT apps Synced, certaines ne sont pas encore Healthy)${RESET}"
else
  echo -e "${YELLOW}⚠️  Installation terminée avec avertissements${RESET}"
  echo -e "${YELLOW}   ($FINAL_SYNCED/$EXPECTED_APPS_COUNT apps Synced, $FINAL_SYNCED_HEALTHY/$EXPECTED_APPS_COUNT apps Healthy)${RESET}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ApplicationSets et Applications
APPSET_COUNT=$(kubectl get applicationset -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
echo -e "${GREEN}📱 ApplicationSets créés: ${BOLD}$APPSET_COUNT${RESET} (attendu: $EXPECTED_APPS_COUNT)"
echo -e "${GREEN}📱 Applications générées: ${BOLD}$FINAL_TOTAL${RESET} (attendu: $EXPECTED_APPS_COUNT)"
echo ""
kubectl get application -A -o custom-columns=\
NAME:.metadata.name,\
NAMESPACE:.metadata.namespace,\
SYNC:.status.sync.status,\
HEALTH:.status.health.status 2>/dev/null

echo ""

# =============================================================================
# Services accessibles - Détection de tous les types de routing
# =============================================================================
# Supporte: Ingress, HTTPRoute/GRPCRoute/TLSRoute (Gateway API),
#           ApisixRoute (APISIX), VirtualService (Istio), IngressRoute (Traefik)

ALL_HOSTS=""

# 1. Kubernetes Ingress (standard)
INGRESS_HOSTS=$(kubectl get ingress -A -o json 2>/dev/null | jq -r '.items[].spec.rules[]?.host // empty' 2>/dev/null | sort -u)
[[ -n "$INGRESS_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${INGRESS_HOSTS}\n"

# 2. Gateway API HTTPRoute
HTTPROUTE_HOSTS=$(kubectl get httproute -A -o json 2>/dev/null | jq -r '.items[].spec.hostnames[]? // empty' 2>/dev/null | sort -u)
[[ -n "$HTTPROUTE_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${HTTPROUTE_HOSTS}\n"

# 3. Gateway API GRPCRoute
GRPCROUTE_HOSTS=$(kubectl get grpcroute -A -o json 2>/dev/null | jq -r '.items[].spec.hostnames[]? // empty' 2>/dev/null | sort -u)
[[ -n "$GRPCROUTE_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${GRPCROUTE_HOSTS}\n"

# 4. Gateway API TLSRoute (SNI-based)
TLSROUTE_HOSTS=$(kubectl get tlsroute -A -o json 2>/dev/null | jq -r '.items[].spec.hostnames[]? // empty' 2>/dev/null | sort -u)
[[ -n "$TLSROUTE_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${TLSROUTE_HOSTS}\n"

# 5. APISIX CRDs - ApisixRoute
APISIXROUTE_HOSTS=$(kubectl get apisixroute -A -o json 2>/dev/null | jq -r '.items[].spec.http[]?.match.hosts[]? // empty' 2>/dev/null | sort -u)
[[ -n "$APISIXROUTE_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${APISIXROUTE_HOSTS}\n"

# 6. Istio VirtualService
VIRTUALSERVICE_HOSTS=$(kubectl get virtualservice -A -o json 2>/dev/null | jq -r '.items[].spec.hosts[]? // empty' 2>/dev/null | grep -v '^\*' | sort -u)
[[ -n "$VIRTUALSERVICE_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${VIRTUALSERVICE_HOSTS}\n"

# 7. Traefik IngressRoute
INGRESSROUTE_HOSTS=$(kubectl get ingressroute -A -o json 2>/dev/null | jq -r '.items[].spec.routes[]?.match // empty' 2>/dev/null | grep -oP 'Host\(`\K[^`]+' | sort -u)
[[ -n "$INGRESSROUTE_HOSTS" ]] && ALL_HOSTS="${ALL_HOSTS}${INGRESSROUTE_HOSTS}\n"

# Combiner et dédupliquer les hosts
ALL_HOSTS=$(echo -e "$ALL_HOSTS" | grep -v '^$' | sort -u)

if [[ -n "$ALL_HOSTS" ]]; then
  echo -e "${GREEN}🌐 Services accessibles:${RESET}"
  echo "$ALL_HOSTS" | while read -r host; do
    [[ -n "$host" ]] && echo -e "  • \033[36mhttps://${host}\033[0m"
  done
  echo ""

  # Identifiants ArgoCD
  echo -e "${YELLOW}🔑 Identifiants ArgoCD:${RESET}"
  echo "  Login: admin"
  ARGOCD_PASSWORD=$(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<secret-not-found>")
  echo "  Password: $ARGOCD_PASSWORD"
  echo ""
else
  echo -e "${YELLOW}⚠️  Aucune ressource de routing déployée${RESET}"
  echo -e "${YELLOW}   (Ingress, HTTPRoute, ApisixRoute, VirtualService, IngressRoute...)${RESET}"
  echo ""
fi

# Accès au cluster
echo -e "${YELLOW}📝 Pour accéder au cluster:${RESET}"
if [[ -n "$KUBECONFIG" ]]; then
  echo "  export KUBECONFIG=$KUBECONFIG"
else
  echo "  export KUBECONFIG=${SCRIPT_DIR}/../../vagrant/.kube/config-${ENVIRONMENT}"
fi
echo "  kubectl get nodes"
echo ""

# =============================================================================
# Résumé de la configuration déployée
# =============================================================================

echo ""
echo -e "${GREEN}🔧 Configuration déployée:${RESET}"
echo "  MetalLB:           $FEAT_METALLB"
echo "  Kube-VIP:          $FEAT_KUBEVIP"
echo "  Gateway API:       $FEAT_GATEWAY_API (httpRoute: $FEAT_GATEWAY_HTTPROUTE, controller: $FEAT_GATEWAY_CONTROLLER)"
echo "  Cert-Manager:      $FEAT_CERT_MANAGER"
echo "  External-Secrets:  $FEAT_EXTERNAL_SECRETS"
echo "  External-DNS:      $FEAT_EXTERNAL_DNS"
echo "  Service Mesh:      $FEAT_SERVICE_MESH ($FEAT_SERVICE_MESH_PROVIDER)"
echo "  Storage:           $FEAT_STORAGE ($FEAT_STORAGE_PROVIDER)"
echo "  Database Operator: $FEAT_DATABASE_OPERATOR ($FEAT_DATABASE_PROVIDER)"
echo "  Monitoring:        $FEAT_MONITORING"
echo "  Cilium Monitoring: $FEAT_CILIUM_MONITORING"
echo "  Cilium Egress:     $FEAT_CILIUM_EGRESS_POLICY"
echo "  Cilium Ingress:    $FEAT_CILIUM_INGRESS_POLICY"
echo "  Tracing:           $FEAT_TRACING ($FEAT_TRACING_PROVIDER)"
echo "  ServiceMesh Waypoints: $FEAT_SERVICEMESH_WAYPOINTS"
echo "  SSO:               $FEAT_SSO ($FEAT_SSO_PROVIDER)"
echo "  OAuth2-Proxy:      $FEAT_OAUTH2_PROXY"
echo "  NeuVector:         $FEAT_NEUVECTOR"
echo ""

log_success "Déploiement terminé! 🎉"
