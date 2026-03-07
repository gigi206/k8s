#!/bin/bash
# =============================================================================
# lib_progress.sh - Barre de progression pour scripts d'installation
# =============================================================================
# Usage:
#   source lib_progress.sh
#   progress_init 10 "Installation K8s"
#   progress_step "Téléchargement RKE2"
#   progress_step "CIS Hardening"
#   ...
#   progress_bar 75 "Synced+Healthy" "15/20"
# =============================================================================

# Couleurs (désactivées si NO_COLOR est défini)
if [[ -z "${NO_COLOR}" ]] && [[ -t 1 ]]; then
  _PB_GREEN='\033[32m'
  _PB_BLUE='\033[34m'
  _PB_BOLD='\033[1m'
  _PB_RESET='\033[0m'
else
  _PB_GREEN='' _PB_BLUE='' _PB_BOLD='' _PB_RESET=''
fi

_PB_TOTAL=0
_PB_CURRENT=0
_PB_TITLE=""

# --- Barre ▓░ ---
# Usage: _pb_bar <pct> <width>
_pb_bar() {
  local pct=$1 width=${2:-20}
  local filled=$(( (pct * width + 50) / 100 ))
  [[ $filled -gt $width ]] && filled=$width
  local empty=$((width - filled))
  local bar=""
  [[ $filled -gt 0 ]] && bar=$(printf '▓%.0s' $(seq 1 $filled))
  [[ $empty -gt 0 ]] && bar="${bar}$(printf '░%.0s' $(seq 1 $empty))"
  printf "%s" "$bar"
}

# =============================================================================
# API publique
# =============================================================================

# progress_init <total_steps> <title>
# Initialise la barre de progression globale
progress_init() {
  _PB_TOTAL=$1
  _PB_TITLE="${2:-Installation}"
  _PB_CURRENT=0
  echo ""
  echo -e "${_PB_BOLD}${_PB_BLUE}━━━ ${_PB_TITLE} ━━━${_PB_RESET}"
}

# progress_step <description>
# Avance d'une étape et affiche la barre globale
progress_step() {
  local desc="$1"
  _PB_CURRENT=$((_PB_CURRENT + 1))

  echo ""
  echo -e "${_PB_BOLD}${_PB_BLUE}━━━ ${_PB_TITLE} (${_PB_CURRENT}/${_PB_TOTAL})${_PB_RESET}"
  echo -e "${_PB_BOLD}▶${_PB_RESET} ${desc}"
}

# progress_done
# Affiche la barre globale à 100%
progress_done() {
  echo ""
  echo -e "${_PB_BOLD}${_PB_GREEN}━━━ ${_PB_TITLE} (${_PB_TOTAL}/${_PB_TOTAL}) ━━━${_PB_RESET}"
}

# progress_bar <pct> <label> <detail>
# Affiche une barre inline (pour les boucles d'attente)
# Écrase la ligne précédente avec \r
progress_bar() {
  local pct=$1 label="${2:-}" detail="${3:-}"
  local bar
  bar=$(_pb_bar "$pct" 20)

  local info=""
  [[ -n "$label" ]] && info=" ${label}"
  [[ -n "$detail" ]] && info="${info} (${detail})"

  printf "\r  ${_PB_BLUE}${bar}${_PB_RESET} %3d%%${info}" "$pct"
}

# progress_bar_done <label> <detail>
# Finalise une barre inline à 100%
progress_bar_done() {
  local label="${1:-}" detail="${2:-}"
  local bar=$(_pb_bar 100 20)
  local info=""
  [[ -n "$label" ]] && info=" ${label}"
  [[ -n "$detail" ]] && info="${info} (${detail})"

  printf "\r  ${_PB_GREEN}${bar}${_PB_RESET} 100%%${info}\n"
}
