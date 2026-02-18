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
  TIMEOUT_APPS_GENERATION  Timeout for Applications generation (default: 240s)
  TIMEOUT_APPS_SYNC     Timeout for Applications sync (default: 900s)
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
  local progress_shown=0

  log_info "$description"

  while true; do
    # Effacer la barre de progression avant d'appeler le callback
    # pour que son log_success s'affiche sur une ligne propre
    [[ $progress_shown -eq 1 ]] && printf "\r\033[K"

    if $condition_func; then
      return 0
    fi

    if [[ $elapsed -ge $timeout ]]; then
      log_warning "Timeout après ${timeout}s: $description"
      return 1
    fi

    # Barre de progression simple
    progress_shown=1
    local progress=$((elapsed * 100 / timeout))
    local bar_len=$((progress * 20 / 100))
    [[ $bar_len -lt 0 ]] && bar_len=0
    printf "\r  [%-20s] %3d%% (%ds/%ds)" \
      "$(printf '#%.0s' $(seq 1 $bar_len) 2>/dev/null)" \
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
  # Note: "" (empty string) is treated as false (used by CI to disable features
  # in a way that is also falsy in Go templates / ArgoCD merge generator)
  case "$value" in
    true|True|TRUE|yes|Yes|YES|1) echo "true" ;;
    false|False|FALSE|no|No|NO|0|"") echo "false" ;;
    null) echo "$default" ;;
    *) echo "$value" ;;
  esac
}

log_info "Lecture des feature flags depuis config.yaml..."

# Lecture des feature flags
FEAT_LB_ENABLED=$(get_feature '.features.loadBalancer.enabled' 'true')
FEAT_LB_PROVIDER=$(get_feature '.features.loadBalancer.provider' 'metallb')
FEAT_KYVERNO=$(get_feature '.features.kyverno.enabled' 'true')
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
FEAT_S3=$(get_feature '.features.s3.enabled' 'false')
FEAT_S3_PROVIDER=$(get_feature '.features.s3.provider' 'rook')
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
FEAT_KUBESCAPE=$(get_feature '.features.kubescape.enabled' 'false')
FEAT_REGISTRY=$(get_feature '.features.registry.enabled' 'false')
FEAT_REGISTRY_PROVIDER=$(get_feature '.features.registry.provider' 'harbor')
FEAT_TRACING=$(get_feature '.features.tracing.enabled' 'false')
FEAT_TRACING_PROVIDER=$(get_feature '.features.tracing.provider' 'jaeger')
FEAT_SERVICEMESH_WAYPOINTS=$(get_feature '.features.serviceMesh.waypoints.enabled' 'false')
# CNI-agnostic network policy flags (moved from features.cilium.* to features.networkPolicy.*)
FEAT_NP_EGRESS_POLICY=$(get_feature '.features.networkPolicy.egressPolicy.enabled' 'true')
FEAT_NP_INGRESS_POLICY=$(get_feature '.features.networkPolicy.ingressPolicy.enabled' 'true')
FEAT_NP_DEFAULT_DENY_POD_INGRESS=$(get_feature '.features.networkPolicy.defaultDenyPodIngress.enabled' 'true')
# Calico-specific features
FEAT_CALICO_MONITORING=$(get_feature '.features.calico.monitoring.enabled' 'true')
FEAT_CILIUM_ENCRYPTION=$(get_feature '.features.cilium.encryption.enabled' 'true')
FEAT_CILIUM_ENCRYPTION_TYPE=$(get_feature '.features.cilium.encryption.type' 'wireguard')
FEAT_CILIUM_MUTUAL_AUTH=$(get_feature '.features.cilium.mutualAuth.enabled' 'true')
FEAT_SPIRE_DATA_STORAGE=$(get_feature '.features.cilium.mutualAuth.spire.dataStorage.enabled' 'false')
FEAT_SPIRE_DATA_STORAGE_SIZE=$(get_feature '.features.cilium.mutualAuth.spire.dataStorage.size' '1Gi')
FEAT_STORAGE_CLASS=$(get_feature '.features.storage.class' 'ceph-block')
FEAT_CONTAINER_RUNTIME=$(get_feature '.features.containerRuntime.enabled' 'false')
FEAT_CONTAINER_RUNTIME_PROVIDER=$(get_feature '.features.containerRuntime.provider' 'kata')
FEAT_CONTAINER_RUNTIME_DEFAULT_CLASS=$(get_feature '.features.containerRuntime.defaultRuntimeClass' '')

# Read Istio mTLS setting from per-app config (if Istio service mesh is active)
FEAT_ISTIO_MTLS="false"
if [[ "$FEAT_SERVICE_MESH" == "true" ]] && [[ "$FEAT_SERVICE_MESH_PROVIDER" == "istio" ]]; then
  ISTIO_CONFIG="${SCRIPT_DIR}/apps/istio/config/${ENVIRONMENT}.yaml"
  if [[ -f "$ISTIO_CONFIG" ]]; then
    _istio_mtls_val=$(yq -r '.istio.mtls.enabled // "false"' "$ISTIO_CONFIG" 2>/dev/null)
    case "$_istio_mtls_val" in
      true|True|TRUE|yes|Yes|YES|1) FEAT_ISTIO_MTLS="true" ;;
      *) FEAT_ISTIO_MTLS="false" ;;
    esac
  fi
fi

# CNI configuration
FEAT_CNI_PRIMARY=$(get_feature '.cni.primary' 'cilium')
FEAT_CNI_MULTUS=$(get_feature '.cni.multus.enabled' 'false')
FEAT_CNI_WHEREABOUTS=$(get_feature '.cni.multus.whereabouts' 'true')

log_debug "Feature flags lus:"
log_debug "  loadBalancer: $FEAT_LB_ENABLED (provider: $FEAT_LB_PROVIDER)"
log_debug "  kyverno: $FEAT_KYVERNO"
log_debug "  kubeVip: $FEAT_KUBEVIP"
log_debug "  gatewayAPI: $FEAT_GATEWAY_API (httpRoute: $FEAT_GATEWAY_HTTPROUTE, controller: $FEAT_GATEWAY_CONTROLLER)"
log_debug "  certManager: $FEAT_CERT_MANAGER"
log_debug "  externalSecrets: $FEAT_EXTERNAL_SECRETS"
log_debug "  reloader: $FEAT_RELOADER"
log_debug "  externalDns: $FEAT_EXTERNAL_DNS"
log_debug "  serviceMesh: $FEAT_SERVICE_MESH ($FEAT_SERVICE_MESH_PROVIDER)"
log_debug "  storage: $FEAT_STORAGE ($FEAT_STORAGE_PROVIDER)"
log_debug "  s3: $FEAT_S3 (provider: $FEAT_S3_PROVIDER)"
log_debug "  csiSnapshotter: $FEAT_CSI_SNAPSHOTTER"
log_debug "  databaseOperator: $FEAT_DATABASE_OPERATOR ($FEAT_DATABASE_PROVIDER)"
log_debug "  monitoring: $FEAT_MONITORING"
log_debug "  cilium.monitoring: $FEAT_CILIUM_MONITORING"
log_debug "  logging: $FEAT_LOGGING (loki: $FEAT_LOGGING_LOKI, collector: $FEAT_LOGGING_COLLECTOR)"
log_debug "  sso: $FEAT_SSO ($FEAT_SSO_PROVIDER)"
log_debug "  oauth2Proxy: $FEAT_OAUTH2_PROXY"
log_debug "  neuvector: $FEAT_NEUVECTOR"
log_debug "  kubescape: $FEAT_KUBESCAPE"
log_debug "  registry: $FEAT_REGISTRY ($FEAT_REGISTRY_PROVIDER)"
log_debug "  tracing: $FEAT_TRACING ($FEAT_TRACING_PROVIDER)"
log_debug "  serviceMesh.waypoints: $FEAT_SERVICEMESH_WAYPOINTS"
log_debug "  networkPolicy.egressPolicy: $FEAT_NP_EGRESS_POLICY"
log_debug "  networkPolicy.ingressPolicy: $FEAT_NP_INGRESS_POLICY"
log_debug "  networkPolicy.defaultDenyPodIngress: $FEAT_NP_DEFAULT_DENY_POD_INGRESS"
log_debug "  calico.monitoring: $FEAT_CALICO_MONITORING"
log_debug "  cilium.encryption: $FEAT_CILIUM_ENCRYPTION ($FEAT_CILIUM_ENCRYPTION_TYPE)"
log_debug "  cilium.mutualAuth: $FEAT_CILIUM_MUTUAL_AUTH"
log_debug "  cilium.mutualAuth.spire.dataStorage: $FEAT_SPIRE_DATA_STORAGE (size: $FEAT_SPIRE_DATA_STORAGE_SIZE)"
log_debug "  containerRuntime: $FEAT_CONTAINER_RUNTIME ($FEAT_CONTAINER_RUNTIME_PROVIDER, defaultClass: ${FEAT_CONTAINER_RUNTIME_DEFAULT_CLASS:-none})"
log_debug "  cni.primary: $FEAT_CNI_PRIMARY"
log_debug "  cni.multus: $FEAT_CNI_MULTUS"
log_debug "  cni.whereabouts: $FEAT_CNI_WHEREABOUTS"

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
      elif [[ "$FEAT_GATEWAY_CONTROLLER" == "apisix" ]]; then
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
    # s3.provider=rook → storage.enabled + storage.provider=rook
    # =========================================================================
    if [[ "$FEAT_S3" == "true" ]] && [[ "$FEAT_S3_PROVIDER" == "rook" ]]; then
      if [[ "$FEAT_STORAGE" != "true" ]]; then
        log_info "  → Activation de storage (requis par s3.provider=rook)"
        FEAT_STORAGE="true"
        FEAT_STORAGE_PROVIDER="rook"
        changes_made=true
      elif [[ "$FEAT_STORAGE_PROVIDER" != "rook" ]]; then
        log_warning "  → Changement storage.provider vers 'rook' (requis par s3.provider=rook)"
        FEAT_STORAGE_PROVIDER="rook"
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

  # ==========================================================================
  # Validation CNI primaire vs providers qui dépendent de Cilium
  # ==========================================================================
  # Ces fonctionnalités nécessitent Cilium comme CNI primaire :
  # - loadBalancer.provider: cilium (Cilium LB-IPAM)
  # - cilium.monitoring.enabled (Cilium/Hubble ServiceMonitors)
  # - cilium.egressPolicy.enabled (CiliumClusterwideNetworkPolicy)
  # - cilium.ingressPolicy.enabled (CiliumClusterwideNetworkPolicy)
  # - cilium.defaultDenyPodIngress.enabled (CiliumClusterwideNetworkPolicy)

  # Vérifier loadBalancer.provider=cilium nécessite CNI Cilium
  if [[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "cilium" ]]; then
    if [[ "$FEAT_CNI_PRIMARY" != "cilium" ]]; then
      log_error "loadBalancer.provider=cilium nécessite cni.primary=cilium"
      log_error "  Cilium LB-IPAM utilise les CRDs CiliumLoadBalancerIPPool qui nécessitent Cilium CNI"
      log_error "  Changez cni.primary: cilium dans config.yaml"
      errors=$((errors + 1))
    fi
  fi

  # Vérifier gatewayAPI.controller.provider=cilium nécessite CNI Cilium
  if [[ "$FEAT_GATEWAY_API" == "true" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" == "cilium" ]]; then
    if [[ "$FEAT_CNI_PRIMARY" != "cilium" ]]; then
      log_error "gatewayAPI.controller.provider=cilium nécessite cni.primary=cilium"
      log_error "  Cilium Gateway API utilise le proxy Envoy intégré à Cilium CNI"
      log_error "  Changez cni.primary: cilium dans config.yaml"
      errors=$((errors + 1))
    fi
  fi

  # Vérifier CNI primary est valide
  case "$FEAT_CNI_PRIMARY" in
    cilium|calico) ;;
    *)
      log_error "cni.primary=$FEAT_CNI_PRIMARY non supporté (valeurs: cilium, calico)"
      errors=$((errors + 1))
      ;;
  esac

  # Vérifier les conflits entre Cilium et Istio mTLS (uniquement si Cilium est le CNI actif)
  if [[ "$FEAT_ISTIO_MTLS" == "true" ]] && [[ "$FEAT_CNI_PRIMARY" == "cilium" ]]; then
    if [[ "$FEAT_CILIUM_MUTUAL_AUTH" == "true" ]]; then
      log_error "Conflit: features.cilium.mutualAuth.enabled=true et istio.mtls.enabled=true"
      log_error "  Cilium SPIFFE/SPIRE et Istio utilisent des systèmes d'identité SPIFFE concurrents"
      log_error "  Désactiver l'un des deux: features.cilium.mutualAuth.enabled ou istio.mtls.enabled"
      errors=$((errors + 1))
    fi
    if [[ "$FEAT_CILIUM_ENCRYPTION" == "true" ]]; then
      log_error "Double chiffrement détecté: features.cilium.encryption.enabled=true et istio.mtls.enabled=true"
      log_error "  Cilium WireGuard et Istio ztunnel chiffrent tous deux le trafic inter-pods"
      log_error "  Désactiver l'un des deux pour éviter la surcharge de performance"
      errors=$((errors + 1))
    fi
  fi

  # Vérifier que loxilb avec Cilium nécessite Multus CNI pour isolation eBPF
  if [[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "loxilb" ]]; then
    if [[ "$FEAT_CNI_MULTUS" != "true" ]]; then
      log_error "LoxiLB nécessite Multus CNI pour fonctionner avec Cilium"
      log_error "  LoxiLB et Cilium utilisent tous deux des hooks eBPF/XDP et entrent en conflit"
      log_error "  Activer: cni.multus.enabled: true dans config.yaml"
      log_error "  Puis recréer le cluster avec: make vagrant-dev-destroy && make dev-full"
      log_error "  Voir: deploy/argocd/apps/loxilb/README.md pour plus de détails"
      errors=$((errors + 1))
    else
      log_info "LoxiLB avec Multus CNI: configuration valide"
    fi
  fi

  # Vérifier que Multus n'est activé que si le CNI primaire le supporte
  if [[ "$FEAT_CNI_MULTUS" == "true" ]] && [[ "$FEAT_CNI_PRIMARY" != "cilium" ]]; then
    log_warning "Multus CNI avec cni.primary=$FEAT_CNI_PRIMARY non testé"
    log_warning "  Seule la combinaison Multus + Cilium est supportée"
  fi

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

  # Vérifier que le S3 provider est supporté
  if [[ "$FEAT_S3" == "true" ]]; then
    case "$FEAT_S3_PROVIDER" in
      rook) ;;  # OK
      *)
        log_error "S3 provider '$FEAT_S3_PROVIDER' non supporté (seul 'rook' est disponible)"
        errors=$((errors + 1))
        ;;
    esac

    # Vérifier cohérence s3.provider=rook + storage.provider=rook
    if [[ "$FEAT_S3_PROVIDER" == "rook" ]] && [[ "$FEAT_STORAGE_PROVIDER" != "rook" ]]; then
      log_error "s3.provider=rook nécessite storage.provider=rook (actuel: $FEAT_STORAGE_PROVIDER)"
      errors=$((errors + 1))
    fi
  fi

  # Vérifier que le gateway controller est supporté
  case "$FEAT_GATEWAY_CONTROLLER" in
    istio|nginx-gateway-fabric|nginx-gwf|envoy-gateway|apisix|traefik|nginx|cilium|"") ;;  # OK
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

# Load Balancer (provider-based)
# metallb: MetalLB handles L2 announcements
# cilium: Cilium LB-IPAM with L2 announcements (configured in apps/cilium/kustomize/lb-ipam/)
# loxilb: LoxiLB eBPF-based load balancer (CNI-agnostic, DSR support)
# kube-vip: kube-vip-cloud-provider handles IPAM, kube-vip handles L2/ARP announcements
# klipper: ServiceLB (RKE2/K3s built-in), uses node IPs - no ApplicationSet needed
[[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "metallb" ]] && APPLICATIONSETS+=("apps/metallb/applicationset.yaml")
[[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "loxilb" ]] && APPLICATIONSETS+=("apps/loxilb/applicationset.yaml")
[[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "kube-vip" ]] && APPLICATIONSETS+=("apps/kube-vip-cloud-provider/applicationset.yaml")
# kube-vip provider requires kubeVip.enabled=true (kube-vip announces VIPs via ARP)
if [[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "kube-vip" ]] && [[ "$FEAT_KUBEVIP" != "true" ]]; then
  log_error "loadBalancer.provider=kube-vip requires features.kubeVip.enabled=true"
  log_error "  kube-vip-cloud-provider handles IPAM, but kube-vip is needed to announce VIPs via ARP"
  log_error "  Please set 'features.kubeVip.enabled: true' in config.yaml"
  exit 1
fi
# klipper: No ApplicationSet deployed - ServiceLB is built into RKE2 (enabled via enable-servicelb: true)
if [[ "$FEAT_LB_ENABLED" == "true" ]] && [[ "$FEAT_LB_PROVIDER" == "klipper" ]]; then
  log_info "Klipper (ServiceLB) mode: no LoadBalancer ApplicationSet deployed"
  log_warning "  Note: staticIP annotations will be ignored (Klipper uses node IPs)"
fi

# Container Runtime Sandboxing (kata, gvisor, spin)
if [[ "$FEAT_CONTAINER_RUNTIME" == "true" ]]; then
  case "$FEAT_CONTAINER_RUNTIME_PROVIDER" in
    kata)
      APPLICATIONSETS+=("apps/kata-containers/applicationset.yaml")
      ;;
    *)
      log_warning "Container runtime provider '$FEAT_CONTAINER_RUNTIME_PROVIDER' is not yet supported"
      ;;
  esac
fi

# API HA + Gateway API CRDs
[[ "$FEAT_KUBEVIP" == "true" ]] && APPLICATIONSETS+=("apps/kube-vip/applicationset.yaml")
# gateway-api-controller installe les CRDs Gateway API, sauf si apisix, traefik ou envoy-gateway est le provider
# (ces controllers incluent leurs propres CRDs Gateway API dans leur chart Helm)
[[ "$FEAT_GATEWAY_API" == "true" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" != "apisix" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" != "traefik" ]] && [[ "$FEAT_GATEWAY_CONTROLLER" != "envoy-gateway" ]] && APPLICATIONSETS+=("apps/gateway-api-controller/applicationset.yaml")

# Policy Engine (deployed separately in Phase 1.1 to avoid chicken-and-egg
# problem: Kyverno mutates pods before PolicyExceptions are deployed, which can
# block apps with PreSync hook Jobs due to immutable spec.template)
KYVERNO_APPSET=""
[[ "$FEAT_KYVERNO" == "true" ]] && KYVERNO_APPSET="apps/kyverno/applicationset.yaml"

# Certificates
[[ "$FEAT_CERT_MANAGER" == "true" ]] && APPLICATIONSETS+=("apps/cert-manager/applicationset.yaml")

# Secrets Management (deployed separately in Phase 1.2)
EXTERNAL_SECRETS_APPSET=""
[[ "$FEAT_EXTERNAL_SECRETS" == "true" ]] && EXTERNAL_SECRETS_APPSET="apps/external-secrets/applicationset.yaml"

# Configuration Reload (auto-reload pods on ConfigMap/Secret changes)
[[ "$FEAT_RELOADER" == "true" ]] && APPLICATIONSETS+=("apps/reloader/applicationset.yaml")

# DNS
[[ "$FEAT_EXTERNAL_DNS" == "true" ]] && APPLICATIONSETS+=("apps/external-dns/applicationset.yaml")

# Service Mesh + Gateway Controller
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

# GitOps Controller (toujours déployé)
APPLICATIONSETS+=("apps/argocd/applicationset.yaml")

# Storage
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

# Database Operator
if [[ "$FEAT_DATABASE_OPERATOR" == "true" ]]; then
  case "$FEAT_DATABASE_PROVIDER" in
    cnpg)
      APPLICATIONSETS+=("apps/cnpg-operator/applicationset.yaml")
      ;;
  esac
fi

# Logging (Loki + collector)
if [[ "$FEAT_LOGGING" == "true" ]] && [[ "$FEAT_LOGGING_LOKI" == "true" ]]; then
  APPLICATIONSETS+=("apps/loki/applicationset.yaml")
  case "$FEAT_LOGGING_COLLECTOR" in
    alloy)
      APPLICATIONSETS+=("apps/alloy/applicationset.yaml")
      ;;
  esac
fi

# Monitoring (prometheus-stack + cilium)
if [[ "$FEAT_MONITORING" == "true" ]]; then
  APPLICATIONSETS+=("apps/prometheus-stack/applicationset.yaml")
fi

# Cilium (CNI installé par RKE2, cette app ajoute monitoring + network policies)
if [[ "$FEAT_CILIUM_MONITORING" == "true" ]] && [[ "$FEAT_MONITORING" == "true" ]] && [[ "$FEAT_CNI_PRIMARY" == "cilium" ]]; then
  APPLICATIONSETS+=("apps/cilium/applicationset.yaml")
fi

# Calico (CNI installé par RKE2, cette app ajoute monitoring + network policies)
if [[ "$FEAT_CALICO_MONITORING" == "true" ]] && [[ "$FEAT_MONITORING" == "true" ]] && [[ "$FEAT_CNI_PRIMARY" == "calico" ]]; then
  APPLICATIONSETS+=("apps/calico/applicationset.yaml")
fi

# Distributed Tracing
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

# SSO + OAuth2-Proxy
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

# Container Registry
if [[ "$FEAT_REGISTRY" == "true" ]]; then
  case "$FEAT_REGISTRY_PROVIDER" in
    harbor)
      APPLICATIONSETS+=("apps/harbor/applicationset.yaml")
      ;;
  esac
fi

# Kubescape (Kubernetes security scanning)
[[ "$FEAT_KUBESCAPE" == "true" ]] && APPLICATIONSETS+=("apps/kubescape/applicationset.yaml")

# Calculer le nombre d'applications attendues
# En environnement dev/local, chaque ApplicationSet génère 1 Application
# En environnement prod, certains ApplicationSets peuvent générer plusieurs Applications (HA)
EXPECTED_APPS_COUNT=${#APPLICATIONSETS[@]}
# Include Kyverno in the count (deployed separately in Phase 1.1)
[[ -n "$KYVERNO_APPSET" ]] && EXPECTED_APPS_COUNT=$((EXPECTED_APPS_COUNT + 1))
# Include external-secrets in the count (deployed separately in Phase 1.2)
[[ -n "$EXTERNAL_SECRETS_APPSET" ]] && EXPECTED_APPS_COUNT=$((EXPECTED_APPS_COUNT + 1))
log_debug "Nombre d'Applications attendues: $EXPECTED_APPS_COUNT"

# Afficher la liste finale
log_info "ApplicationSets à déployer (${#APPLICATIONSETS[@]}):"
[[ -n "$KYVERNO_APPSET" ]] && log_debug "  - $KYVERNO_APPSET (Phase 1.1)"
[[ -n "$EXTERNAL_SECRETS_APPSET" ]] && log_debug "  - $EXTERNAL_SECRETS_APPSET (Phase 1.2)"
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
# Pré-déploiement des NetworkPolicies (bootstrap)
# =============================================================================
# Ordre d'application:
# 1. ClusterwideNetworkPolicy (default-deny-external-egress)
#    → Autorise le trafic interne (cluster, kube-apiserver, DNS) pour tous les pods
#    → Bloque l'egress externe (world) par défaut
# 2. NetworkPolicy ArgoCD
#    → Ajoute l'accès externe (GitHub, Helm registries) pour ArgoCD uniquement
#
# Sans ces policies pré-appliquées, ArgoCD ne peut pas accéder à GitHub pour
# récupérer sa propre configuration (chicken-and-egg problem).

apply_bootstrap_network_policies_cilium() {
  if [[ "$FEAT_NP_EGRESS_POLICY" != "true" ]] && [[ "$FEAT_NP_INGRESS_POLICY" != "true" ]]; then
    log_debug "Cilium policies désactivées, pas de pré-déploiement nécessaire"
    return 0
  fi

  log_info "Pré-déploiement des CiliumNetworkPolicies pour bootstrap..."

  # 1. Egress clusterwide policy - bloque le trafic externe, autorise le trafic interne
  if [[ "$FEAT_NP_EGRESS_POLICY" == "true" ]]; then
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
  if [[ "$FEAT_NP_INGRESS_POLICY" == "true" ]]; then
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
  # Note: La règle Keycloak OIDC est ajoutée conditionnellement par l'ApplicationSet
  # uniquement si provider=apisix + sso.enabled + sso.provider=keycloak
  if [[ "$FEAT_NP_EGRESS_POLICY" == "true" ]]; then
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
  if [[ "$FEAT_NP_DEFAULT_DENY_POD_INGRESS" == "true" ]]; then
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
  if [[ "$FEAT_NP_INGRESS_POLICY" == "true" ]]; then
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
      cilium)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/cilium-ingress-policy-cilium.yaml"
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

  # 5. Default deny pod ingress (Zero Trust baseline)
  if [[ "$FEAT_NP_DEFAULT_DENY_POD_INGRESS" == "true" ]]; then
    local pod_ingress_policy="${SCRIPT_DIR}/apps/cilium/resources/default-deny-pod-ingress.yaml"
    if [[ -f "$pod_ingress_policy" ]]; then
      if kubectl apply -f "$pod_ingress_policy" > /dev/null 2>&1; then
        log_success "CiliumClusterwideNetworkPolicy default-deny-pod-ingress appliquée"
      else
        log_warning "Impossible d'appliquer la CiliumClusterwideNetworkPolicy default-deny-pod-ingress"
      fi
    else
      log_debug "Pas de pod ingress policy trouvée: $pod_ingress_policy"
    fi

    # 6. SPIRE ingress policy (Agent <-> Server communication)
    # Must be applied WITH default-deny-pod-ingress to avoid blocking SPIRE
    # during Cilium restarts (mutual auth deadlock prevention)
    if [[ "$FEAT_CILIUM_MUTUAL_AUTH" == "true" ]]; then
      local spire_ingress_policy="${SCRIPT_DIR}/apps/cilium/resources/cilium-spire-ingress-policy.yaml"
      if [[ -f "$spire_ingress_policy" ]]; then
        if kubectl apply -f "$spire_ingress_policy" > /dev/null 2>&1; then
          log_success "CiliumNetworkPolicy SPIRE ingress appliquée (Agent <-> Server)"
        else
          log_warning "Impossible d'appliquer la CiliumNetworkPolicy SPIRE ingress"
        fi
      else
        log_debug "Pas de SPIRE ingress policy trouvée: $spire_ingress_policy"
      fi
    fi
  fi

  # Wait for Cilium to propagate policies to endpoints
  log_info "Attente de la propagation des policies Cilium (10s)..."
  sleep 10
}

apply_bootstrap_network_policies_calico() {
  if [[ "$FEAT_NP_EGRESS_POLICY" != "true" ]] && [[ "$FEAT_NP_INGRESS_POLICY" != "true" ]]; then
    log_debug "Network policies désactivées, pas de pré-déploiement nécessaire"
    return 0
  fi

  log_info "Pré-déploiement des GlobalNetworkPolicies Calico pour bootstrap..."

  # 1. Egress clusterwide policy - bloque le trafic externe, autorise le trafic interne
  if [[ "$FEAT_NP_EGRESS_POLICY" == "true" ]]; then
    local egress_policy="${SCRIPT_DIR}/apps/calico/resources/default-deny-external-egress.yaml"
    if [[ -f "$egress_policy" ]]; then
      if kubectl apply -f "$egress_policy" > /dev/null 2>&1; then
        log_success "GlobalNetworkPolicy egress appliquée (trafic interne autorisé)"
      else
        log_warning "Impossible d'appliquer la GlobalNetworkPolicy egress"
      fi
    else
      log_debug "Pas de egress policy trouvée: $egress_policy"
    fi
  fi

  # 2. Host ingress policy - protège les nœuds (SSH, API, HTTP/HTTPS autorisés)
  if [[ "$FEAT_NP_INGRESS_POLICY" == "true" ]]; then
    local ingress_policy="${SCRIPT_DIR}/apps/calico/resources/default-deny-host-ingress.yaml"
    if [[ -f "$ingress_policy" ]]; then
      if kubectl apply -f "$ingress_policy" > /dev/null 2>&1; then
        log_success "GlobalNetworkPolicy host ingress appliquée (SSH, API, Kubelet, ICMP)"
      else
        log_warning "Impossible d'appliquer la GlobalNetworkPolicy host ingress"
      fi
    else
      log_debug "Pas de host ingress policy trouvée: $ingress_policy"
    fi
  fi

  # 3. ArgoCD egress policy - ajoute l'accès externe (GitHub, Helm)
  if [[ "$FEAT_NP_EGRESS_POLICY" == "true" ]]; then
    local argocd_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-egress-policy.yaml"
    if [[ -f "$argocd_policy" ]]; then
      if kubectl apply -f "$argocd_policy" > /dev/null 2>&1; then
        log_success "Calico NetworkPolicy ArgoCD egress appliquée (accès GitHub/Helm)"
      else
        log_warning "Impossible d'appliquer la Calico NetworkPolicy ArgoCD egress"
      fi
    else
      log_debug "Pas de egress policy ArgoCD trouvée: $argocd_policy"
    fi
  fi

  # 4. ArgoCD ingress policy - permet la communication interne ArgoCD
  if [[ "$FEAT_NP_DEFAULT_DENY_POD_INGRESS" == "true" ]]; then
    local argocd_internal_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy.yaml"
    if [[ -f "$argocd_internal_policy" ]]; then
      if kubectl apply -f "$argocd_internal_policy" > /dev/null 2>&1; then
        log_success "Calico NetworkPolicy ArgoCD ingress appliquée (internal)"
      else
        log_warning "Impossible d'appliquer la Calico NetworkPolicy ArgoCD ingress (internal)"
      fi
    fi
  fi

  # Policy gateway (external access) - séparée par provider
  if [[ "$FEAT_NP_INGRESS_POLICY" == "true" ]]; then
    local argocd_ingress_policy=""
    case "$FEAT_GATEWAY_CONTROLLER" in
      istio)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy-istio.yaml"
        ;;
      apisix)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy-apisix.yaml"
        ;;
      traefik)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy-traefik.yaml"
        ;;
      nginx-gateway-fabric|nginx-gwf)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy-nginx-gwf.yaml"
        ;;
      envoy-gateway)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy-envoy-gateway.yaml"
        ;;
      cilium)
        argocd_ingress_policy="${SCRIPT_DIR}/apps/argocd/resources/calico-ingress-policy-cilium.yaml"
        ;;
      *)
        log_warning "Provider Gateway inconnu: $FEAT_GATEWAY_CONTROLLER - pas de policy gateway ArgoCD"
        ;;
    esac
    if [[ -n "$argocd_ingress_policy" && -f "$argocd_ingress_policy" ]]; then
      if kubectl apply -f "$argocd_ingress_policy" > /dev/null 2>&1; then
        log_success "Calico NetworkPolicy ArgoCD ingress appliquée ($FEAT_GATEWAY_CONTROLLER)"
      else
        log_warning "Impossible d'appliquer la Calico NetworkPolicy ArgoCD ingress ($FEAT_GATEWAY_CONTROLLER)"
      fi
    fi
  fi

  # Wait for Calico to propagate policies
  log_info "Attente de la propagation des policies Calico (10s)..."
  sleep 10
}

# Dispatch bootstrap network policies based on CNI
if [[ "$FEAT_CNI_PRIMARY" == "cilium" ]]; then
  apply_bootstrap_network_policies_cilium
elif [[ "$FEAT_CNI_PRIMARY" == "calico" ]]; then
  apply_bootstrap_network_policies_calico
fi

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
# Helper: Apply CI patches and strip monitoring blocks from a manifest file
# =============================================================================
apply_manifest_patches() {
  local manifest_file="$1"

  if [[ -n "${CI_GIT_BRANCH:-}" ]]; then
    log_info "CI mode: patching for branch '${CI_GIT_BRANCH}'"
    sed -i "s|revision: 'HEAD'|revision: '${CI_GIT_BRANCH}'|g" "$manifest_file"
    sed -i "s|targetRevision: '{{ .git.revision }}'|targetRevision: '${CI_GIT_BRANCH}'|g" "$manifest_file"
  fi

  # Strip monitoring blocks from templates when monitoring is disabled
  # Required because ArgoCD merge generator converts all values to strings,
  # making {{- if .features.monitoring.enabled }} truthy even when "false"
  # CI uses empty string "" (falsy in Go templates) but we keep this as safety net
  if [[ "$FEAT_MONITORING" != "true" ]]; then
    log_info "Stripping monitoring blocks from templates (monitoring disabled)"
    if command -v perl &> /dev/null; then
      perl -i -0777 -pe 's/\{\{-\s*if\s+\.features\.monitoring\.enabled\s*\}\}.*?\{\{-\s*end\s*\}\}//gs' "$manifest_file"
    fi
  fi
}

# =============================================================================
# Phase 1.1: Deploy Kyverno first + pre-apply PolicyExceptions
# =============================================================================
# Kyverno mutates pods to set automountServiceAccountToken=false. Apps have
# PolicyExceptions to opt out, but the exceptions must exist BEFORE Kyverno
# processes app resources. Without this, PreSync hook Jobs get mutated and
# become stuck (spec.template is immutable on Jobs, so ArgoCD can't update them).

TEMP_MANIFEST=$(mktemp)
trap "rm -f $TEMP_MANIFEST" EXIT

if [[ -n "$KYVERNO_APPSET" ]]; then
  echo ""
  log_info "Phase 1.1: Déploiement de Kyverno (policy engine)..."

  # Deploy Kyverno ApplicationSet
  cat "${SCRIPT_DIR}/${KYVERNO_APPSET}" > "$TEMP_MANIFEST"
  apply_manifest_patches "$TEMP_MANIFEST"

  if [[ $VERBOSE -eq 1 ]]; then
    kubectl apply -f "$TEMP_MANIFEST"
  else
    kubectl apply -f "$TEMP_MANIFEST" > /dev/null
  fi
  log_success "ApplicationSet Kyverno déployé"

  # Wait for Kyverno to be Healthy (not Synced - ServiceMonitor CRDs may not exist yet)
  check_kyverno_healthy() {
    local health
    health=$(kubectl get application kyverno -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null)
    if [[ "$health" == "Healthy" ]]; then
      log_success "Kyverno est Healthy"
      return 0
    fi
    return 1
  }

  wait_for_condition \
    "Attente de Kyverno (Healthy)..." \
    "$TIMEOUT_APPS_SYNC" \
    check_kyverno_healthy || {
      log_warning "Kyverno non Healthy - les PolicyExceptions pourraient ne pas fonctionner"
    }

  # Pre-apply all PolicyExceptions for apps that will be deployed
  log_info "Pré-déploiement des PolicyExceptions..."
  pe_count=0

  for appset in "${APPLICATIONSETS[@]}"; do
    app_dir="${SCRIPT_DIR}/$(dirname "$appset")"

    # Support multiple PolicyException files per app (kyverno-policy-exception*.yaml)
    for pe_file in "${app_dir}"/resources/kyverno-policy-exception*.yaml; do
      [[ -f "$pe_file" ]] || continue
      pe_ns=$(yq -r '.metadata.namespace' "$pe_file" 2>/dev/null)

      if [[ -n "$pe_ns" ]] && [[ "$pe_ns" != "null" ]]; then
        # Create namespace if it doesn't exist
        if ! kubectl get namespace "$pe_ns" &> /dev/null; then
          kubectl create namespace "$pe_ns" > /dev/null 2>&1 || true
          log_debug "  Namespace créé: $pe_ns"
        fi

        if kubectl apply -f "$pe_file" > /dev/null 2>&1; then
          pe_count=$((pe_count + 1))
          log_debug "  PolicyException: $pe_ns"
        else
          log_warning "  Échec PolicyException: $pe_file"
        fi
      fi
    done
  done

  # SPIRE PolicyException: must be applied regardless of whether the cilium
  # ApplicationSet is in APPLICATIONSETS[] (it's conditional on monitoring).
  # Without this, SPIRE pods lose their SA token when Kyverno mutates them,
  # causing mutual auth to block ALL inter-pod traffic (deadlock).
  if [[ "$FEAT_CNI_PRIMARY" == "cilium" ]] && [[ "$FEAT_CILIUM_MUTUAL_AUTH" == "true" ]]; then
    spire_pe="${SCRIPT_DIR}/apps/cilium/resources/kyverno-policy-exception-spire.yaml"
    if [[ -f "$spire_pe" ]]; then
      spire_ns=$(yq -r '.metadata.namespace' "$spire_pe" 2>/dev/null)
      if [[ -n "$spire_ns" ]] && [[ "$spire_ns" != "null" ]]; then
        if ! kubectl get namespace "$spire_ns" &> /dev/null; then
          kubectl create namespace "$spire_ns" > /dev/null 2>&1 || true
          log_debug "  Namespace créé: $spire_ns"
        fi
        if kubectl apply -f "$spire_pe" > /dev/null 2>&1; then
          pe_count=$((pe_count + 1))
          log_debug "  PolicyException SPIRE: $spire_ns (mutual auth)"
        else
          log_warning "  Échec PolicyException SPIRE: $spire_pe"
        fi
      fi
    fi
  fi

  log_success "PolicyExceptions pré-déployées: $pe_count"
fi

# =============================================================================
# Phase 1.2: Deploy external-secrets (webhook must be ready before dependent apps)
# =============================================================================
if [[ -n "$EXTERNAL_SECRETS_APPSET" ]]; then
  echo ""
  log_info "Phase 1.2: Déploiement de external-secrets (secret management)..."

  cat "${SCRIPT_DIR}/${EXTERNAL_SECRETS_APPSET}" > "$TEMP_MANIFEST"
  apply_manifest_patches "$TEMP_MANIFEST"

  if [[ $VERBOSE -eq 1 ]]; then
    kubectl apply -f "$TEMP_MANIFEST"
  else
    kubectl apply -f "$TEMP_MANIFEST" > /dev/null
  fi
  log_success "ApplicationSet external-secrets déployé"

  check_external_secrets_healthy() {
    local health
    health=$(kubectl get application external-secrets -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null)
    [[ "$health" == "Healthy" ]] && { log_success "External-secrets est Healthy (webhook opérationnel)"; return 0; }
    return 1
  }

  wait_for_condition \
    "Attente de external-secrets (Healthy + webhook prêt)..." \
    "$TIMEOUT_APPS_SYNC" \
    check_external_secrets_healthy || {
      log_warning "External-secrets non Healthy - les ExternalSecrets pourraient échouer"
    }
fi

# =============================================================================
# Phase 2: Deploy remaining ApplicationSets
# =============================================================================

echo ""
log_info "Phase 2: Déploiement des ApplicationSets..."

# Build manifest with all remaining ApplicationSets
> "$TEMP_MANIFEST"
for appset in "${APPLICATIONSETS[@]}"; do
  appset_path="${SCRIPT_DIR}/${appset}"
  cat "$appset_path" >> "$TEMP_MANIFEST"
  echo "---" >> "$TEMP_MANIFEST"
done

apply_manifest_patches "$TEMP_MANIFEST"

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
  local expected=$EXPECTED_APPS_COUNT

  if [[ $current -ge $expected ]]; then
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
    printf "\r  [%-20s] %3d%% (%d/%d Applications)\n" \
      "$(printf '#%.0s' $(seq 1 20))" \
      100 "$current_apps" "$EXPECTED_APPS_COUNT"
    log_success "Toutes les Applications générées: $current_apps/$EXPECTED_APPS_COUNT"
    break
  fi

  # Timeout
  if [[ $apps_gen_elapsed -ge $TIMEOUT_APPS_GENERATION ]]; then
    printf "\n"
    log_error "Timeout après ${TIMEOUT_APPS_GENERATION}s: $current_apps/$EXPECTED_APPS_COUNT Applications générées"
    echo ""
    log_info "État des Applications ArgoCD:"
    kubectl get applications -A -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,NAMESPACE:.spec.destination.namespace' 2>/dev/null || echo "  (aucune application trouvée)"
    echo ""
    log_info "État des ApplicationSets:"
    kubectl get applicationsets -A -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].type,MESSAGE:.status.conditions[0].message' 2>/dev/null || echo "  (aucun applicationset trouvé)"
    echo ""
    log_info "Logs du ApplicationSet Controller:"
    kubectl logs -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-applicationset-controller --tail=20 2>/dev/null || echo "  (logs indisponibles)"
    exit 1
  fi

  # Barre de progression
  progress=$((current_apps * 100 / EXPECTED_APPS_COUNT))
  bar_len=$((progress * 20 / 100))
  [[ $bar_len -lt 0 ]] && bar_len=0
  printf "\r  [%-20s] %3d%% (%d/%d Applications)" \
    "$(printf '#%.0s' $(seq 1 $bar_len) 2>/dev/null)" \
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

  bar_len=$((progress * 20 / 100))
  [[ $bar_len -lt 0 ]] && bar_len=0
  if [[ $WAIT_HEALTHY -eq 1 ]]; then
    printf "\r  [%-20s] %3d%% (%d/%d Synced+Healthy, %ds)" \
      "$(printf '#%.0s' $(seq 1 $bar_len) 2>/dev/null)" \
      "$progress" "$SYNCED_AND_HEALTHY" "$target_apps" "$sync_elapsed"
  else
    printf "\r  [%-20s] %3d%% (%d/%d Synced+Healthy)" \
      "$(printf '#%.0s' $(seq 1 $bar_len) 2>/dev/null)" \
      "$progress" "$SYNCED_AND_HEALTHY" "$target_apps"
  fi

  log_debug "Synced: $SYNCED, Healthy: $HEALTHY, Total: $TOTAL_APPS, Expected: $EXPECTED_APPS_COUNT"

  # Condition de succès: toutes les apps attendues sont synced et healthy
  if [[ $SYNCED_AND_HEALTHY -ge $EXPECTED_APPS_COUNT ]] && [[ $TOTAL_APPS -ge $EXPECTED_APPS_COUNT ]]; then
    # Afficher la barre de progression finale à 100%
    if [[ $WAIT_HEALTHY -eq 1 ]]; then
      printf "\r  [%-20s] %3d%% (%d/%d Synced+Healthy, %ds)\n" \
        "$(printf '#%.0s' $(seq 1 20))" \
        100 "$SYNCED_AND_HEALTHY" "$EXPECTED_APPS_COUNT" "$sync_elapsed"
    else
      printf "\r  [%-20s] %3d%% (%d/%d Synced+Healthy)\n" \
        "$(printf '#%.0s' $(seq 1 20))" \
        100 "$SYNCED_AND_HEALTHY" "$EXPECTED_APPS_COUNT"
    fi
    log_success "Toutes les applications sont Synced + Healthy! ($SYNCED_AND_HEALTHY/$EXPECTED_APPS_COUNT)"
    break
  fi

  # Timeout (sauf si --wait-healthy)
  if [[ $WAIT_HEALTHY -eq 0 ]] && [[ $sync_elapsed -ge $TIMEOUT_APPS_SYNC ]]; then
    printf "\n"
    log_error "Timeout après ${TIMEOUT_APPS_SYNC}s: $SYNCED_AND_HEALTHY/$EXPECTED_APPS_COUNT apps Synced + Healthy"
    echo ""
    log_error "Applications avec problèmes:"
    echo "$APPS_JSON" | jq -r '.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy") | "  - \(.metadata.name): Sync=\(.status.sync.status // "Unknown") Health=\(.status.health.status // "Unknown")"'
    exit 1
  fi

  # Cilium Gateway API: bootstrap one-shot du GatewayClass + restart Operator
  # Problème double:
  # 1. Cilium Helm s'installe avec gatewayClass.create="auto", mais les CRDs
  #    Gateway API n'existent pas encore → Helm skip la création du GatewayClass
  # 2. L'Operator démarre SANS les CRDs → ne lance pas son contrôleur Gateway API
  # Solution: quand les CRDs arrivent (via gateway-api-controller), on:
  #   a) Crée le GatewayClass manuellement (Cilium Helm l'adoptera au prochain upgrade)
  #   b) Redémarre l'Operator pour qu'il initialise son contrôleur Gateway API
  if [[ "$FEAT_GATEWAY_CONTROLLER" == "cilium" ]] && [[ ${_cilium_gw_created:-0} -eq 0 ]]; then
    if kubectl get crd gatewayclasses.gateway.networking.k8s.io &>/dev/null; then
      _cilium_gw_created=1
      if ! kubectl get gatewayclass cilium &>/dev/null; then
        printf "\r\033[K"
        log_warning "GatewayClass 'cilium' absent — création manuelle..."
        kubectl apply --server-side --force-conflicts -f - <<'GWEOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
GWEOF
      fi
      # Restart Operator si le contrôleur Gateway API n'est pas actif
      # (GatewayClass.status.conditions[0].reason == "Pending" signifie que l'Operator
      # n'a pas initialisé son contrôleur Gateway API car les CRDs étaient absentes au boot)
      gc_accepted=""
      gc_accepted=$(kubectl get gatewayclass cilium -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)
      if [[ "$gc_accepted" != "True" ]]; then
        log_info "Restart du Cilium Operator (contrôleur Gateway API non initialisé)..."
        kubectl -n kube-system rollout restart deployment/cilium-operator
        kubectl -n kube-system rollout status deployment/cilium-operator --timeout=120s
      fi
    fi
  fi

  sleep $sync_interval
  sync_elapsed=$((sync_elapsed + sync_interval))
done

# =============================================================================
# Phase 2.5: Migration SPIRE emptyDir -> PVC (stockage persistant)
# =============================================================================
# Au bootstrap, SPIRE utilise emptyDir car aucun storage provider n'existe encore
# (chicken-and-egg: SPIRE boot avant Rook/Longhorn). Maintenant que toutes les
# apps sont Synced+Healthy (incluant le storage provider), on peut migrer vers PVC.
#
# Séquence:
# 1. Vérifier si la migration est nécessaire (dataStorage.enabled=false dans HelmChartConfig)
# 2. Attendre que le storage provider soit Ready (CephCluster ou StorageClass)
# 3. Patcher le HelmChartConfig K8s pour activer dataStorage
# 4. Supprimer le fichier rke2-cilium-config.yaml du disque via un Job K8s
# 5. Le Helm controller détecte le changement et fait un helm upgrade automatique

migrate_spire_storage() {
  echo ""
  log_info "Phase 2.5: Migration SPIRE storage (emptyDir → PVC)..."

  # --- Vérifier si la migration est nécessaire ---
  local current_values
  current_values=$(kubectl get helmchartconfig rke2-cilium -n kube-system -o jsonpath='{.spec.valuesContent}' 2>/dev/null || true)
  if [[ -z "$current_values" ]]; then
    log_warning "HelmChartConfig rke2-cilium non trouvé, skip migration"
    return 0
  fi

  # Vérifier si dataStorage est déjà activé
  local current_data_storage
  current_data_storage=$(echo "$current_values" | yq -r '.authentication.mutual.spire.install.server.dataStorage.enabled // "false"' 2>/dev/null)
  if [[ "$current_data_storage" == "true" ]]; then
    log_success "SPIRE dataStorage déjà activé (PVC), migration non nécessaire"
    return 0
  fi

  log_info "SPIRE dataStorage actuellement désactivé (emptyDir), migration vers PVC..."

  # --- Attendre que le storage soit prêt ---
  check_storage_ready() {
    case "$FEAT_STORAGE_PROVIDER" in
      rook)
        # Vérifier CephCluster Ready
        local ceph_phase
        ceph_phase=$(kubectl get cephcluster -n rook-ceph -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [[ "$ceph_phase" != "Ready" ]]; then
          return 1
        fi
        # Vérifier CephBlockPool Ready
        local pool_phase
        pool_phase=$(kubectl get cephblockpool -n rook-ceph -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [[ "$pool_phase" != "Ready" ]]; then
          return 1
        fi
        log_success "Rook Ceph storage prêt (CephCluster: Ready, CephBlockPool: Ready)"
        return 0
        ;;
      longhorn)
        # Vérifier que la StorageClass existe
        if kubectl get storageclass "$FEAT_STORAGE_CLASS" &>/dev/null; then
          log_success "Longhorn storage prêt (StorageClass: $FEAT_STORAGE_CLASS)"
          return 0
        fi
        return 1
        ;;
      *)
        # Pour les autres providers, vérifier juste la StorageClass
        if kubectl get storageclass "$FEAT_STORAGE_CLASS" &>/dev/null; then
          log_success "Storage prêt (StorageClass: $FEAT_STORAGE_CLASS)"
          return 0
        fi
        return 1
        ;;
    esac
  }

  if ! wait_for_condition \
    "Attente du storage provider ($FEAT_STORAGE_PROVIDER)..." \
    "$TIMEOUT_APPS_SYNC" \
    check_storage_ready; then
    log_warning "Storage non prêt dans le timeout, SPIRE reste en emptyDir (fonctionnel)"
    return 0
  fi

  # --- Patcher le HelmChartConfig ---
  log_info "Patch du HelmChartConfig rke2-cilium (activation dataStorage)..."

  # Modifier le valuesContent avec yq
  local new_values
  new_values=$(echo "$current_values" | yq -r '
    .authentication.mutual.spire.install.server.dataStorage.enabled = true |
    .authentication.mutual.spire.install.server.dataStorage.storageClass = "'"$FEAT_STORAGE_CLASS"'" |
    .authentication.mutual.spire.install.server.dataStorage.size = "'"$FEAT_SPIRE_DATA_STORAGE_SIZE"'"
  ' 2>/dev/null)

  if [[ -z "$new_values" ]] || [[ "$new_values" == "null" ]]; then
    log_error "Échec de la modification du valuesContent avec yq"
    return 0
  fi

  # Appliquer le patch via kubectl
  local patch_json
  patch_json=$(jq -n --arg vc "$new_values" '{"spec":{"valuesContent":$vc}}')

  if kubectl patch helmchartconfig rke2-cilium -n kube-system --type merge -p "$patch_json" > /dev/null 2>&1; then
    log_success "HelmChartConfig patché (dataStorage: enabled, storageClass: $FEAT_STORAGE_CLASS, size: $FEAT_SPIRE_DATA_STORAGE_SIZE)"
  else
    log_error "Échec du patch HelmChartConfig, skip la suppression du fichier"
    return 0
  fi

  # --- Supprimer le fichier rke2-cilium-config.yaml du disque via Job ---
  log_info "Suppression du fichier rke2-cilium-config.yaml du disque (Job K8s)..."

  # Supprimer un éventuel Job précédent
  kubectl delete job spire-storage-file-cleanup -n kube-system --ignore-not-found > /dev/null 2>&1

  kubectl apply -f - <<'JOBEOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: spire-storage-file-cleanup
  namespace: kube-system
  labels:
    app.kubernetes.io/name: spire-storage-migration
    app.kubernetes.io/part-of: cilium
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 3
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: CriticalAddonsOnly
          operator: Exists
      restartPolicy: OnFailure
      containers:
        - name: cleanup
          image: busybox:1.37
          command:
            - /bin/sh
            - -c
            - |
              if [ -f /manifests/rke2-cilium-config.yaml ]; then
                rm -f /manifests/rke2-cilium-config.yaml
                echo "rke2-cilium-config.yaml supprimé avec succès"
              else
                echo "rke2-cilium-config.yaml déjà absent"
              fi
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: manifests
              mountPath: /manifests
      volumes:
        - name: manifests
          hostPath:
            path: /var/lib/rancher/rke2/server/manifests
            type: Directory
JOBEOF

  # Attendre la fin du Job
  if kubectl wait --for=condition=complete job/spire-storage-file-cleanup -n kube-system --timeout=120s > /dev/null 2>&1; then
    log_success "Fichier rke2-cilium-config.yaml supprimé du disque"
  else
    log_warning "Job de suppression non terminé (le fichier reste sur disque, non bloquant)"
  fi

  # --- Attendre que le Helm controller ait fini de traiter le changement ---
  # Le patch du HelmChartConfig déclenche un helm upgrade asynchrone.
  # Si le upgrade échoue (ex: volumeClaimTemplates StatefulSet immutables lors
  # du passage emptyDir -> PVC), failurePolicy: reinstall déclenche un cycle:
  #   helm uninstall (SUPPRESSION de toutes les ressources Cilium/SPIRE)
  #   -> helm install (recréation complète avec nouvelles valeurs)
  # Pendant cette fenêtre, les ressources n'existent pas. On doit attendre
  # que le DaemonSet Cilium existe ET soit ready avant toute opération rollout.

  check_cilium_post_helm() {
    local ready
    ready=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null)
    [[ -n "$ready" ]] && [[ "$ready" -ge 1 ]]
  }

  if ! wait_for_condition \
    "Attente du Helm controller (DaemonSet Cilium ready)..." \
    600 \
    check_cilium_post_helm; then
    log_warning "Cilium DaemonSet non disponible après 600s, tentative de continuer..."
  fi

  # --- Séquençage post-migration: Cilium -> SPIRE Server -> SPIRE Agent ---
  # Après un helm upgrade classique (rolling-update), Cilium et SPIRE redémarrent
  # simultanément: le SPIRE agent tente de se reconnecter pendant le rechargement
  # eBPF, les connexions gRPC cassent, l'agent entre en backoff exponentiel.
  # Après un helm reinstall (fresh install), les pods sont neufs et n'ont pas
  # de backoff. Le séquençage ci-dessous gère les deux cas via des if guards.

  # Étape 1: Attendre SPIRE Server Ready
  log_info "Attente du SPIRE Server StatefulSet..."
  if kubectl rollout status statefulset/spire-server -n cilium-spire --timeout=300s > /dev/null 2>&1; then
    log_success "SPIRE Server StatefulSet prêt"
  else
    log_warning "SPIRE Server rollout timeout (300s), tentative de continuer..."
  fi

  # Étape 2: Restart propre du SPIRE Agent (seulement si nécessaire)
  # Après un helm upgrade, le SPIRE agent peut rester en backoff exponentiel
  # à cause des connexions gRPC cassées par le rechargement eBPF de Cilium.
  # Après un helm reinstall, les pods sont frais -> le restart est inutile mais inoffensif.
  log_info "Restart propre du SPIRE Agent (évite backoff exponentiel)..."
  if kubectl rollout restart daemonset/spire-agent -n cilium-spire > /dev/null 2>&1 && \
     kubectl rollout status daemonset/spire-agent -n cilium-spire --timeout=120s > /dev/null 2>&1; then
    log_success "SPIRE Agent DaemonSet redémarré avec succès"
  else
    log_warning "SPIRE Agent restart/rollout échoué (120s), tentative de continuer..."
  fi

  # Étape 3: Restart Cilium Operator (reconnexion au SPIRE Agent)
  # Le restart du SPIRE Agent (étape 2) casse la connexion gRPC Unix socket
  # du Cilium Operator vers le SPIRE Agent. Sans ce restart, l'operator ne
  # re-enregistre pas les nouvelles identités Cilium créées par les workloads
  # ArgoCD déployés après le batch initial, causant des erreurs
  # "no SPIFFE ID for spiffe://spiffe.cilium/identity/XXXX".
  log_info "Restart du Cilium Operator (reconnexion SPIRE agent)..."
  if kubectl rollout restart deployment/cilium-operator -n kube-system > /dev/null 2>&1 && \
     kubectl rollout status deployment/cilium-operator -n kube-system --timeout=60s > /dev/null 2>&1; then
    log_success "Cilium Operator redémarré avec succès"
  else
    log_warning "Cilium Operator restart/rollout échoué (60s), tentative de continuer..."
  fi

  # Attendre que l'operator re-enregistre les identités dans SPIRE
  sleep 15

  # Étape 4: Vérifier la connectivité SPIRE (agent peut communiquer avec server)
  check_spire_operational() {
    # Vérifier que le spire-server StatefulSet a ses replicas ready
    local server_ready
    server_ready=$(kubectl get statefulset spire-server -n cilium-spire -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    local server_replicas
    server_replicas=$(kubectl get statefulset spire-server -n cilium-spire -o jsonpath='{.status.replicas}' 2>/dev/null)
    if [[ -z "$server_ready" ]] || [[ "$server_ready" -lt 1 ]] || [[ "$server_ready" != "$server_replicas" ]]; then
      return 1
    fi
    # Vérifier que le spire-agent DaemonSet a ses pods ready
    local agent_desired
    agent_desired=$(kubectl get daemonset spire-agent -n cilium-spire -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
    local agent_ready
    agent_ready=$(kubectl get daemonset spire-agent -n cilium-spire -o jsonpath='{.status.numberReady}' 2>/dev/null)
    if [[ -z "$agent_ready" ]] || [[ "$agent_ready" -lt 1 ]] || [[ "$agent_ready" != "$agent_desired" ]]; then
      return 1
    fi
    # Vérifier que l'agent n'a pas d'erreurs récentes (backoff, connexion refusée)
    local agent_pod
    agent_pod=$(kubectl get pods -n cilium-spire -l app=spire-agent -o name 2>/dev/null | head -1)
    if [[ -n "$agent_pod" ]]; then
      local recent_errors
      recent_errors=$(kubectl logs "$agent_pod" -n cilium-spire --tail=5 --since=10s 2>/dev/null | grep -ci "error" || true)
      if [[ "$recent_errors" -gt 0 ]]; then
        return 1
      fi
    fi
    # Vérifier que l'auth table eBPF se remplit (SPIRE émet des identités)
    # Sans cette vérification, on peut passer avec un SPIRE "healthy" mais
    # dont le Cilium Operator n'a pas re-enregistré les identités après restart.
    local auth_entries
    local cilium_pod
    cilium_pod=$(kubectl get pods -n kube-system -l k8s-app=cilium -o name 2>/dev/null | head -1)
    auth_entries=$(kubectl exec -n kube-system "$cilium_pod" -- cilium-dbg bpf auth list 2>/dev/null | grep -c "spire" || echo "0")
    if [[ "$auth_entries" -lt 5 ]]; then
      return 1
    fi
    log_success "SPIRE opérationnel (server: $server_ready/$server_replicas, agent: $agent_ready/$agent_desired, auth_entries: $auth_entries, pas d'erreurs récentes)"
    return 0
  }

  if wait_for_condition \
    "Vérification connectivité SPIRE (server + agent + pas d'erreurs)..." \
    "$TIMEOUT_APPS_SYNC" \
    check_spire_operational; then
    log_success "Migration SPIRE storage terminée!"
  else
    log_warning "SPIRE non pleinement opérationnel dans le timeout. Le mutual auth peut impacter la connectivité."
    log_warning "  Debug: kubectl logs -n cilium-spire -l app=spire-agent --tail=20"
    log_warning "  Debug: cilium-dbg monitor --type drop (chercher 'Authentication required')"
  fi
}

# Condition d'entrée: cilium CNI + mutual auth + storage + spire dataStorage activés
if [[ "$FEAT_CNI_PRIMARY" == "cilium" ]] && [[ "$FEAT_CILIUM_MUTUAL_AUTH" == "true" ]] && [[ "$FEAT_STORAGE" == "true" ]] && [[ "$FEAT_SPIRE_DATA_STORAGE" == "true" ]]; then
  migrate_spire_storage
else
  log_debug "Migration SPIRE storage non applicable (cni=$FEAT_CNI_PRIMARY, mutualAuth=$FEAT_CILIUM_MUTUAL_AUTH, storage=$FEAT_STORAGE, spireDataStorage=$FEAT_SPIRE_DATA_STORAGE)"
fi

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
echo "  LoadBalancer:      $FEAT_LB_ENABLED ($FEAT_LB_PROVIDER)"
echo "  Kube-VIP:          $FEAT_KUBEVIP"
echo "  Gateway API:       $FEAT_GATEWAY_API (httpRoute: $FEAT_GATEWAY_HTTPROUTE, controller: $FEAT_GATEWAY_CONTROLLER)"
echo "  Cert-Manager:      $FEAT_CERT_MANAGER"
echo "  External-Secrets:  $FEAT_EXTERNAL_SECRETS"
echo "  External-DNS:      $FEAT_EXTERNAL_DNS"
echo "  Service Mesh:      $FEAT_SERVICE_MESH ($FEAT_SERVICE_MESH_PROVIDER)"
echo "  Storage:           $FEAT_STORAGE ($FEAT_STORAGE_PROVIDER)"
echo "  Database Operator: $FEAT_DATABASE_OPERATOR ($FEAT_DATABASE_PROVIDER)"
echo "  Monitoring:        $FEAT_MONITORING"
echo "  CNI Monitoring:    Cilium=$FEAT_CILIUM_MONITORING Calico=$FEAT_CALICO_MONITORING"
echo "  NP Egress:         $FEAT_NP_EGRESS_POLICY"
echo "  NP Ingress:        $FEAT_NP_INGRESS_POLICY"
echo "  NP Pod Ingress:    $FEAT_NP_DEFAULT_DENY_POD_INGRESS"
echo "  Cilium Encryption: $FEAT_CILIUM_ENCRYPTION ($FEAT_CILIUM_ENCRYPTION_TYPE)"
echo "  Cilium Mutual Auth: $FEAT_CILIUM_MUTUAL_AUTH"
echo "  SPIRE DataStorage: $FEAT_SPIRE_DATA_STORAGE (size: $FEAT_SPIRE_DATA_STORAGE_SIZE, class: $FEAT_STORAGE_CLASS)"
echo "  Tracing:           $FEAT_TRACING ($FEAT_TRACING_PROVIDER)"
echo "  ServiceMesh Waypoints: $FEAT_SERVICEMESH_WAYPOINTS"
echo "  SSO:               $FEAT_SSO ($FEAT_SSO_PROVIDER)"
echo "  OAuth2-Proxy:      $FEAT_OAUTH2_PROXY"
echo "  NeuVector:         $FEAT_NEUVECTOR"
echo "  Kubescape:         $FEAT_KUBESCAPE"
echo "  CNI Primary:       $FEAT_CNI_PRIMARY"
echo "  CNI Multus:        $FEAT_CNI_MULTUS"
echo ""

log_success "Déploiement terminé! 🎉"
