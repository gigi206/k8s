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
TIMEOUT_APPS_GENERATION="${TIMEOUT_APPS_GENERATION:-60}"
TIMEOUT_APPS_SYNC="${TIMEOUT_APPS_SYNC:-300}"
TIMEOUT_API_LB="${TIMEOUT_API_LB:-60}"

# Options
VERBOSE=0
ENVIRONMENT=""
GLOBAL_TIMEOUT=""

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
# Liste des ApplicationSets
# =============================================================================

APPLICATIONSETS=(
  "apps/metallb/applicationset.yaml"                    # Wave 10
  "apps/kube-vip/applicationset.yaml"                   # Wave 15
  "apps/gateway-api-controller/applicationset.yaml"     # Wave 15
  "apps/cert-manager/applicationset.yaml"               # Wave 20
  "apps/external-secrets/applicationset.yaml"           # Wave 25
  "apps/external-dns/applicationset.yaml"               # Wave 30
  "apps/istio/applicationset.yaml"                      # Wave 40
  "apps/istio-gateway/applicationset.yaml"              # Wave 41
  "apps/argocd/applicationset.yaml"                     # Wave 50
  "apps/csi-external-snapshotter/applicationset.yaml"   # Wave 55
  "apps/longhorn/applicationset.yaml"                   # Wave 60
  "apps/cnpg-operator/applicationset.yaml"              # Wave 65
  "apps/prometheus-stack/applicationset.yaml"           # Wave 75
  "apps/cilium-monitoring/applicationset.yaml"          # Wave 76
  "apps/keycloak/applicationset.yaml"                   # Wave 80
)

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
check_apps_generated() {
  local current=$(kubectl get application -A --no-headers 2>/dev/null | wc -l)

  if [[ $current -gt 0 ]]; then
    printf "\n"
    log_success "Applications générées: $current"
    return 0
  fi

  log_debug "Applications: $current"
  return 1
}

wait_for_condition \
  "Attente de la génération des Applications..." \
  "$TIMEOUT_APPS_GENERATION" \
  check_apps_generated || {
    log_warning "Aucune Application générée"
    log_info "Vérifiez les logs du ApplicationSet Controller:"
    echo "  kubectl logs -n $ARGOCD_NAMESPACE -l app.kubernetes.io/name=argocd-applicationset-controller"
  }

# =============================================================================
# Attente de la synchronisation des Applications
# =============================================================================

echo ""
log_info "Attente de la synchronisation et santé des Applications..."
elapsed=0

while true; do
  # Récupérer toutes les applications en une seule requête
  APPS_JSON=$(kubectl get application -A -o json 2>/dev/null)
  TOTAL_APPS=$(echo "$APPS_JSON" | jq -r '.items | length')

  if [[ $TOTAL_APPS -eq 0 ]]; then
    log_debug "Aucune application trouvée, attente..."
    sleep 5
    elapsed=$((elapsed + 5))
    continue
  fi

  # Parser le JSON une seule fois
  SYNCED=$(echo "$APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="Synced")] | length')
  HEALTHY=$(echo "$APPS_JSON" | jq -r '[.items[] | select(.status.health.status=="Healthy")] | length')
  SYNCED_AND_HEALTHY=$(echo "$APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')

  # Affichage de l'état
  progress=$((SYNCED_AND_HEALTHY * 100 / TOTAL_APPS))
  printf "\r  État: [%-50s] %d%% (%d/%d apps Synced + Healthy)" \
    "$(printf '#%.0s' $(seq 1 $((progress / 2))))" \
    "$progress" "$SYNCED_AND_HEALTHY" "$TOTAL_APPS"

  log_debug "Synced: $SYNCED, Healthy: $HEALTHY"

  # Condition de succès
  if [[ $SYNCED_AND_HEALTHY -eq $TOTAL_APPS ]] && [[ $TOTAL_APPS -gt 0 ]]; then
    printf "\n"
    log_success "Toutes les applications sont Synced + Healthy!"
    break
  fi

  # Timeout
  if [[ $elapsed -ge $TIMEOUT_APPS_SYNC ]]; then
    printf "\n"
    log_warning "Timeout après ${TIMEOUT_APPS_SYNC}s: $SYNCED_AND_HEALTHY/$TOTAL_APPS apps Synced + Healthy"
    echo ""
    log_warning "Applications avec problèmes:"
    echo "$APPS_JSON" | jq -r '.items[] | select(.status.sync.status!="Synced" or .status.health.status!="Healthy") | "  - \(.metadata.name): Sync=\(.status.sync.status // "Unknown") Health=\(.status.health.status // "Unknown")"'
    break
  fi

  sleep 5
  elapsed=$((elapsed + 5))
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
if [[ $FINAL_SYNCED_HEALTHY -eq $FINAL_TOTAL ]] && [[ $FINAL_TOTAL -gt 0 ]]; then
  echo -e "${GREEN}✅ Installation terminée!${RESET}"
elif [[ $FINAL_OUTOFSYNC_AUTOSYNC -gt 0 ]]; then
  echo -e "${YELLOW}⏳ Installation terminée - Synchronisation automatique en cours...${RESET}"
  echo -e "${YELLOW}   ($FINAL_OUTOFSYNC_AUTOSYNC app(s) OutOfSync avec auto-sync se synchroniseront automatiquement)${RESET}"
  OUTOFSYNC_APPS_LIST=$(echo "$FINAL_APPS_JSON" | jq -r '[.items[] | select(.status.sync.status=="OutOfSync" and (.spec.syncPolicy.automated.prune==true or .spec.syncPolicy.automated.selfHeal==true)) | .metadata.name] | join(", ")')
  echo -e "${YELLOW}   Apps: $OUTOFSYNC_APPS_LIST${RESET}"
elif [[ $FINAL_SYNCED -eq $FINAL_TOTAL ]] && [[ $FINAL_TOTAL -gt 0 ]]; then
  echo -e "${YELLOW}⚠️  Installation terminée avec avertissements${RESET}"
  echo -e "${YELLOW}   ($FINAL_SYNCED/$FINAL_TOTAL apps Synced, certaines ne sont pas encore Healthy)${RESET}"
else
  echo -e "${YELLOW}⚠️  Installation terminée avec avertissements${RESET}"
  echo -e "${YELLOW}   ($FINAL_SYNCED/$FINAL_TOTAL apps Synced, $FINAL_SYNCED_HEALTHY/$FINAL_TOTAL apps Healthy)${RESET}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ApplicationSets et Applications
APPSET_COUNT=$(kubectl get applicationset -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
echo -e "${GREEN}📱 ApplicationSets créés: ${BOLD}$APPSET_COUNT${RESET}"
echo -e "${GREEN}📱 Applications générées: ${BOLD}$FINAL_TOTAL${RESET}"
echo ""
kubectl get application -A -o custom-columns=\
NAME:.metadata.name,\
NAMESPACE:.metadata.namespace,\
SYNC:.status.sync.status,\
HEALTH:.status.health.status 2>/dev/null

echo ""

# Services accessibles via Ingress
INGRESSES=$(kubectl get ingress -A -o json 2>/dev/null)
if [[ -n "$INGRESSES" ]] && [[ $(echo "$INGRESSES" | jq '.items | length') -gt 0 ]]; then
  echo -e "${GREEN}🌐 Services accessibles:${RESET}"
  echo "$INGRESSES" | jq -r '.items[] | "  • \u001b[36mhttps://\(.spec.rules[0].host)\u001b[0m"' 2>/dev/null | sort
  echo ""

  # Identifiants ArgoCD
  echo -e "${YELLOW}🔑 Identifiants ArgoCD:${RESET}"
  echo "  Login: admin"
  ARGOCD_PASSWORD=$(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "<secret-not-found>")
  echo "  Password: $ARGOCD_PASSWORD"
  echo ""
else
  echo -e "${YELLOW}⚠️  Aucun ingress déployé${RESET}"
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

log_success "Déploiement terminé! 🎉"
