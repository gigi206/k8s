.PHONY: help dev-full vagrant-dev-up vagrant-dev-down vagrant-dev-destroy vagrant-dev-status vagrant-dev-ssh vagrant-dev-snapshot-list vagrant-dev-snapshot-save vagrant-dev-snapshot-delete vagrant-dev-snapshot-restore argocd-install-dev vagrant-prod-up vagrant-prod-down vagrant-prod-destroy vagrant-prod-status vagrant-prod-snapshot-list vagrant-prod-snapshot-save vagrant-prod-snapshot-delete vagrant-prod-snapshot-restore vagrant-staging-up vagrant-staging-down vagrant-staging-destroy vagrant-staging-status vagrant-staging-snapshot-list vagrant-staging-snapshot-save vagrant-staging-snapshot-delete vagrant-staging-snapshot-restore clean-all

# Couleurs
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m # No Color

# Chemins
VAGRANT_DIR := $(CURDIR)/vagrant
KUBE_DIR := $(VAGRANT_DIR)/.kube
KUBECONFIG_DEV := $(KUBE_DIR)/config-dev
ARGOCD_DIR := $(CURDIR)/deploy/argocd
ARGOCD_NAMESPACE := argo-cd

# Default target
help:
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)   Kubernetes RKE2 + ArgoCD Infrastructure$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "$(GREEN)🚀 Environnement DEV (1 master all-in-one):$(NC)"
	@echo "  dev-full                         - 🌟 Déploiement complet (RKE2 + ArgoCD + ApplicationSets)"
	@echo "  vagrant-dev-up                   - Créer et démarrer le cluster dev (RKE2 uniquement)"
	@echo "  argocd-install-dev               - Installer ArgoCD + déployer tous les ApplicationSets"
	@echo "  vagrant-dev-status               - Statut du cluster dev"
	@echo "  vagrant-dev-ssh                  - SSH sur le master dev"
	@echo "  vagrant-dev-down                 - Arrêter le cluster dev"
	@echo "  vagrant-dev-destroy              - Détruire le cluster dev"
	@echo "  vagrant-dev-snapshot-list        - Lister les snapshots dev"
	@echo "  vagrant-dev-snapshot-save        - Créer un snapshot dev"
	@echo "  vagrant-dev-snapshot-delete      - Supprimer un snapshot dev"
	@echo "  vagrant-dev-snapshot-restore     - Restaurer un snapshot dev"
	@echo ""
	@echo "$(GREEN)🏗️  Environnement STAGING (3 masters):$(NC)"
	@echo "  vagrant-staging-up               - Créer et démarrer le cluster staging"
	@echo "  vagrant-staging-status           - Statut du cluster staging"
	@echo "  vagrant-staging-down             - Arrêter le cluster staging"
	@echo "  vagrant-staging-destroy          - Détruire le cluster staging"
	@echo "  vagrant-staging-snapshot-list    - Lister les snapshots staging"
	@echo "  vagrant-staging-snapshot-save    - Créer un snapshot staging"
	@echo "  vagrant-staging-snapshot-delete  - Supprimer un snapshot staging"
	@echo "  vagrant-staging-snapshot-restore - Restaurer un snapshot staging"
	@echo ""
	@echo "$(GREEN)🏢 Environnement PROD (3 masters + 3 workers):$(NC)"
	@echo "  vagrant-prod-up                  - Créer et démarrer le cluster prod"
	@echo "  vagrant-prod-status              - Statut du cluster prod"
	@echo "  vagrant-prod-down                - Arrêter le cluster prod"
	@echo "  vagrant-prod-destroy             - Détruire le cluster prod"
	@echo "  vagrant-prod-snapshot-list       - Lister les snapshots prod"
	@echo "  vagrant-prod-snapshot-save       - Créer un snapshot prod"
	@echo "  vagrant-prod-snapshot-delete     - Supprimer un snapshot prod"
	@echo "  vagrant-prod-snapshot-restore    - Restaurer un snapshot prod"
	@echo ""
	@echo ""
	@echo "$(GREEN)🧹 Nettoyage:$(NC)"
	@echo "  clean-all                        - Supprimer tous les clusters et fichiers temporaires"
	@echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  DEV Environment
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

vagrant-dev-up:
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)🚀 Démarrage du cluster DEV (RKE2)$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	cd vagrant && K8S_ENV=dev vagrant up
	@echo ""
	@echo "$(GREEN)✅ Cluster RKE2 DEV démarré!$(NC)"
	@echo ""
	@echo "$(YELLOW)📝 Prochaines étapes:$(NC)"
	@echo "  1. Exporter KUBECONFIG: export KUBECONFIG=$(KUBECONFIG_DEV)"
	@echo "  2. Vérifier le cluster: kubectl get nodes"
	@echo "  3. Déployer ArgoCD: make argocd-install-dev"
	@echo ""

vagrant-dev-status:
	@echo "$(BLUE)📊 Statut du cluster DEV:$(NC)"
	@cd vagrant && K8S_ENV=dev vagrant status

vagrant-dev-ssh:
	@cd vagrant && K8S_ENV=dev vagrant ssh k8s-dev-m1

vagrant-dev-down:
	@echo "$(YELLOW)⏸️  Arrêt du cluster DEV...$(NC)"
	cd vagrant && K8S_ENV=dev vagrant halt

vagrant-dev-destroy:
	@echo "$(YELLOW)⚠️  ATTENTION: Vous êtes sur le point de DÉTRUIRE le cluster DEV$(NC)"
	@read -p "Taper 'yes' pour confirmer: " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1)
	cd vagrant && K8S_ENV=dev vagrant destroy -f
	rm -f $(VAGRANT_DIR)/k8s-token $(VAGRANT_DIR)/ip_master
	rm -rf $(KUBE_DIR)
	@echo "$(GREEN)✅ Cluster DEV détruit et résidus nettoyés$(NC)"

vagrant-dev-snapshot-list:
	@echo "$(BLUE)📸 Snapshots disponibles pour le cluster DEV:$(NC)"
	@cd vagrant && K8S_ENV=dev vagrant snapshot list

vagrant-dev-snapshot-save:
	@echo "$(BLUE)📸 Création d'un snapshot du cluster DEV$(NC)"
	@read -p "Nom du snapshot: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	cd vagrant && K8S_ENV=dev vagrant snapshot save "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' créé avec succès$(NC)"

vagrant-dev-snapshot-delete:
	@echo "$(YELLOW)⚠️  Suppression d'un snapshot du cluster DEV$(NC)"
	@cd vagrant && K8S_ENV=dev vagrant snapshot list
	@echo ""
	@read -p "Nom du snapshot à supprimer: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la suppression de '$$name' (yes): " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=dev vagrant snapshot delete "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' supprimé$(NC)"

vagrant-dev-snapshot-restore:
	@echo "$(YELLOW)⚠️  Restauration d'un snapshot du cluster DEV$(NC)"
	@cd vagrant && K8S_ENV=dev vagrant snapshot list
	@echo ""
	@read -p "Nom du snapshot à restaurer: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la restauration de '$$name' (yes): " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=dev vagrant snapshot restore "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' restauré$(NC)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  STAGING Environment
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

vagrant-staging-up:
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)🏗️  Démarrage du cluster STAGING$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	cd vagrant && K8S_ENV=staging vagrant up

vagrant-staging-status:
	@echo "$(BLUE)📊 Statut du cluster STAGING:$(NC)"
	@cd vagrant && K8S_ENV=staging vagrant status

vagrant-staging-down:
	@echo "$(YELLOW)⏸️  Arrêt du cluster STAGING...$(NC)"
	cd vagrant && K8S_ENV=staging vagrant halt

vagrant-staging-destroy:
	@echo "$(YELLOW)⚠️  ATTENTION: Vous êtes sur le point de DÉTRUIRE le cluster STAGING$(NC)"
	@read -p "Taper 'yes' pour confirmer: " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1)
	cd vagrant && K8S_ENV=staging vagrant destroy -f
	rm -f $(VAGRANT_DIR)/k8s-token $(VAGRANT_DIR)/ip_master
	rm -rf $(KUBE_DIR)
	@echo "$(GREEN)✅ Cluster STAGING détruit et résidus nettoyés$(NC)"

vagrant-staging-snapshot-list:
	@echo "$(BLUE)📸 Snapshots disponibles pour le cluster STAGING:$(NC)"
	@cd vagrant && K8S_ENV=staging vagrant snapshot list

vagrant-staging-snapshot-save:
	@echo "$(BLUE)📸 Création d'un snapshot du cluster STAGING$(NC)"
	@read -p "Nom du snapshot: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	cd vagrant && K8S_ENV=staging vagrant snapshot save "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' créé avec succès$(NC)"

vagrant-staging-snapshot-delete:
	@echo "$(YELLOW)⚠️  Suppression d'un snapshot du cluster STAGING$(NC)"
	@cd vagrant && K8S_ENV=staging vagrant snapshot list
	@echo ""
	@read -p "Nom du snapshot à supprimer: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la suppression de '$$name' (yes): " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=staging vagrant snapshot delete "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' supprimé$(NC)"

vagrant-staging-snapshot-restore:
	@echo "$(YELLOW)⚠️  Restauration d'un snapshot du cluster STAGING$(NC)"
	@cd vagrant && K8S_ENV=staging vagrant snapshot list
	@echo ""
	@read -p "Nom du snapshot à restaurer: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la restauration de '$$name' (yes): " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=staging vagrant snapshot restore "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' restauré$(NC)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PROD Environment
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

vagrant-prod-up:
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)🏢 Démarrage du cluster PROD$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(YELLOW)⚠️  ATTENTION: Vous démarrez un environnement de PRODUCTION$(NC)"
	@read -p "Taper 'yes' pour confirmer: " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1)
	cd vagrant && K8S_ENV=prod vagrant up

vagrant-prod-status:
	@echo "$(BLUE)📊 Statut du cluster PROD:$(NC)"
	@cd vagrant && K8S_ENV=prod vagrant status

vagrant-prod-down:
	@echo "$(YELLOW)⏸️  Arrêt du cluster PROD...$(NC)"
	cd vagrant && K8S_ENV=prod vagrant halt

vagrant-prod-destroy:
	@echo "$(YELLOW)⚠️  ATTENTION: Vous êtes sur le point de DÉTRUIRE le cluster PROD$(NC)"
	@read -p "Taper 'DESTROY-PROD' pour confirmer: " confirm && [ "$$confirm" = "DESTROY-PROD" ] || (echo "Annulé" && exit 1)
	cd vagrant && K8S_ENV=prod vagrant destroy -f
	rm -f $(VAGRANT_DIR)/k8s-token $(VAGRANT_DIR)/ip_master
	rm -rf $(KUBE_DIR)
	@echo "$(GREEN)✅ Cluster PROD détruit et résidus nettoyés$(NC)"

vagrant-prod-snapshot-list:
	@echo "$(BLUE)📸 Snapshots disponibles pour le cluster PROD:$(NC)"
	@cd vagrant && K8S_ENV=prod vagrant snapshot list

vagrant-prod-snapshot-save:
	@echo "$(BLUE)📸 Création d'un snapshot du cluster PROD$(NC)"
	@read -p "Nom du snapshot: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la création du snapshot '$$name' en PROD (yes): " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=prod vagrant snapshot save "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' créé avec succès$(NC)"

vagrant-prod-snapshot-delete:
	@echo "$(YELLOW)⚠️  Suppression d'un snapshot du cluster PROD$(NC)"
	@cd vagrant && K8S_ENV=prod vagrant snapshot list
	@echo ""
	@read -p "Nom du snapshot à supprimer: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la suppression de '$$name' en PROD (DESTROY-SNAPSHOT): " confirm && [ "$$confirm" = "DESTROY-SNAPSHOT" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=prod vagrant snapshot delete "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' supprimé$(NC)"

vagrant-prod-snapshot-restore:
	@echo "$(YELLOW)⚠️  Restauration d'un snapshot du cluster PROD$(NC)"
	@cd vagrant && K8S_ENV=prod vagrant snapshot list
	@echo ""
	@read -p "Nom du snapshot à restaurer: " name && [ -n "$$name" ] || (echo "Nom requis" && exit 1) && \
	read -p "Confirmer la restauration de '$$name' en PROD (RESTORE-PROD): " confirm && [ "$$confirm" = "RESTORE-PROD" ] || (echo "Annulé" && exit 1) && \
	cd vagrant && K8S_ENV=prod vagrant snapshot restore "$$name" && \
	echo "$(GREEN)✅ Snapshot '$$name' restauré$(NC)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ArgoCD Management
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Installation ArgoCD avec ApplicationSets
argocd-install-dev:
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)🎯 Installation ArgoCD + Infrastructure (ApplicationSets)$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "$(GREEN)📦 Étape 1/5: Récupération du kubeconfig...$(NC)"
	@mkdir -p $(KUBE_DIR)
	@cd $(VAGRANT_DIR) && \
		MASTER_IP=$$(K8S_ENV=dev vagrant ssh k8s-dev-m1 -c 'hostname -I | cut -d" " -f1' 2>/dev/null | tr -d '\r\n') && \
		K8S_ENV=dev vagrant ssh k8s-dev-m1 -c "sudo cat /etc/rancher/rke2/rke2.yaml" 2>/dev/null | \
		sed "s/127.0.0.1/$$MASTER_IP/g" > .kube/config-dev
	@export KUBECONFIG=$(KUBECONFIG_DEV) && \
	echo "" && \
	echo "$(GREEN)📚 Étape 2/5: Ajout du repo Helm ArgoCD...$(NC)" && \
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true && \
	helm repo update >/dev/null 2>&1 && \
	echo "" && \
	echo "$(GREEN)🔐 Étape 3/5: Création du namespace et secret SOPS...$(NC)" && \
	kubectl create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic sops-age-key \
		--namespace $(ARGOCD_NAMESPACE) \
		--from-file=keys.txt=$(CURDIR)/sops/age-dev.key \
		--dry-run=client -o yaml | kubectl apply -f - && \
	echo "" && \
	echo "$(GREEN)⚙️  Étape 4/5: Installation ArgoCD via Helm (avec KSOPS)...$(NC)" && \
	K8S_VERSION=$$(kubectl version -o json | jq -r '.serverVersion.gitVersion' | sed 's/^v//; s/+.*//' ) && \
	helm template argocd argo/argo-cd \
		--namespace $(ARGOCD_NAMESPACE) \
		--kube-version $$K8S_VERSION \
		-f $(ARGOCD_DIR)/argocd-bootstrap-values.yaml | kubectl apply --server-side -f - && \
	echo "   Attente du démarrage d'ArgoCD..." && \
	kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=argocd-server -n $(ARGOCD_NAMESPACE) --timeout=10m && \
	echo "" && \
	echo "$(GREEN)🚀 Étape 5/5: Déploiement des ApplicationSets...$(NC)" && \
	cd $(ARGOCD_DIR) && bash deploy-applicationsets.sh

dev-full: vagrant-dev-up argocd-install-dev
	@echo "$(GREEN)✅ Environnement DEV complet déployé!$(NC)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Cleanup
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

clean-all:
	@echo "$(YELLOW)🧹 Nettoyage de tous les environnements...$(NC)"
	@echo "$(YELLOW)⚠️  Cela va supprimer tous les clusters Vagrant$(NC)"
	@read -p "Taper 'yes' pour confirmer: " confirm && [ "$$confirm" = "yes" ] || (echo "Annulé" && exit 1)
	-cd vagrant && K8S_ENV=dev vagrant destroy -f
	-cd vagrant && K8S_ENV=staging vagrant destroy -f
	-cd vagrant && K8S_ENV=prod vagrant destroy -f
	rm -f $(VAGRANT_DIR)/k8s-token $(VAGRANT_DIR)/ip_master
	rm -rf $(KUBE_DIR)
	@echo "$(GREEN)✅ Nettoyage terminé$(NC)"
