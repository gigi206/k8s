# K8s + ArgoCD - Infrastructure GitOps

Infrastructure Kubernetes gérée via ArgoCD ApplicationSets avec templating Go natif.

## 🚀 Installation Complète

```bash
make dev-full
```

**C'est tout !** Cette commande installe automatiquement :
- ✅ Cluster Kubernetes (RKE2) via Vagrant
- ✅ ArgoCD avec ApplicationSet controller
- ✅ 27 ApplicationSets (une par application)
- ✅ Applications essentielles : MetalLB, Cert-Manager, Istio, Longhorn, Prometheus, Keycloak, etc.

## 📝 Mise à jour des applications

Toute la configuration est dans Git. Pour modifier :

```bash
# 1. Modifier la configuration d'un environnement
vim deploy/argocd/config/config.yaml

# 2. Committer et pusher
git add deploy/argocd/config/config.yaml
git commit -m "Update dev configuration"
git push

# 3. ArgoCD détecte et applique automatiquement (auto-sync activé en dev)
```

## 🔧 Commandes utiles

```bash
# Connexion au cluster
export KUBECONFIG=vagrant/kube.config
kubectl get nodes

# Voir les ApplicationSets
kubectl get applicationsets -n argo-cd

# Voir les Applications générées
kubectl get applications -n argo-cd

# Accès ArgoCD UI
kubectl port-forward -n argo-cd svc/argocd-server 8080:443
# Login: admin
# Password: kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## 📁 Structure du projet

```
.
├── Makefile                                 # Commandes principales
├── vagrant/                                 # Cluster Kubernetes (RKE2)
│   └── kube.config                         # Kubeconfig généré
└── deploy/argocd/
    ├── deploy-applicationsets.sh           # 🚀 Déploiement des ApplicationSets
    ├── config/
    │   └── config.yaml                     # ⚙️ Configuration globale + feature flags
    └── apps/                                # 📦 Applications (un dossier par app)
        ├── metallb/
        │   ├── applicationset.yaml
        │   ├── config/dev.yaml             # Config dev
        │   └── resources/                  # Ressources K8s
        ├── cert-manager/
        ├── external-dns/
        ├── ingress-nginx/
        ├── argocd/
        ├── longhorn/
        ├── prometheus-stack/
        └── ...                             # 27 apps au total
```

## 🎯 Environnements disponibles

| Env | Replicas | Auto-sync | Usage |
|-----|----------|-----------|-------|
| **dev** | 1 | ✅ | Développement local |
| **prod** | 3+ | ❌ | Production (sync manuel) |

## 🏗️ Architecture ApplicationSet

```
ApplicationSets (27 apps)
  └─> Lit config depuis Git (config.yaml + app/config/*.yaml)
       └─> Génère Applications automatiquement
            └─> ArgoCD déploie avec sync waves
```

**Avantages** :
- ✅ 100% GitOps (tout dans Git)
- ✅ Pas de Terraform/OpenTofu
- ✅ Go templates natifs ArgoCD
- ✅ Applications générées automatiquement
- ✅ Un fichier de config par environnement

## 🔄 Workflow de développement

### Ajouter une nouvelle application

```bash
# 1. Créer le dossier de l'application
mkdir -p deploy/argocd/apps/my-app/{config,resources}

# 2. Créer l'ApplicationSet (copier un existant comme template)
cp deploy/argocd/apps/metallb/applicationset.yaml deploy/argocd/apps/my-app/

# 3. Créer les fichiers de configuration
vim deploy/argocd/apps/my-app/config/dev.yaml
vim deploy/argocd/apps/my-app/config/prod.yaml

# 4. Ajouter l'app dans deploy-applicationsets.sh

# 5. Committer et pusher
git add deploy/argocd/apps/my-app/
git commit -m "Add my-app application"
git push

# 6. ArgoCD crée automatiquement les Applications
```

### Modifier une application existante

```bash
# Option 1: Modifier la config globale
vim deploy/argocd/config/config.yaml

# Option 2: Modifier la config spécifique à l'app
vim deploy/argocd/apps/my-app/config/dev.yaml

# Dans les deux cas, commit + push = déploiement auto
git add . && git commit -m "Update" && git push
```

## ❓ Dépannage

### Réinstaller proprement

```bash
make vagrant-dev-destroy
make dev-full
```

### Voir les logs ArgoCD

```bash
kubectl logs -n argo-cd deployment/argocd-server -f
kubectl logs -n argo-cd deployment/argocd-applicationset-controller -f
```

### Forcer un refresh

```bash
kubectl -n argo-cd patch application <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Statut des applications

```bash
kubectl get applications -n argo-cd
argocd app list  # Si argocd CLI installé
```

## 📌 Points importants

- **Configuration globale** : `deploy/argocd/config/config.yaml`
- **Configuration par app** : `deploy/argocd/apps/<app>/config/{dev,prod}.yaml`
- **ApplicationSets auto-générés** : Pas besoin de créer les Applications manuellement
- **Auto-sync en dev** : Les changements Git sont appliqués automatiquement
- **Sync manuel en prod** : Contrôle total sur les déploiements

## 🔐 Gestion des secrets (SOPS/KSOPS)

Les secrets sont chiffrés dans Git avec **SOPS** (AGE encryption) et déchiffrés par ArgoCD via **KSOPS**.

```
sops/                    # Clés privées AGE
├── age-dev.key          # Clé dev
└── age-prod.key         # Clé prod

deploy/argocd/
├── .sops.yaml           # Config SOPS (clés publiques)
└── apps/<app>/secrets/  # Secrets chiffrés par application
```

> ⚠️ **Cluster de démo** : Les clés privées dans `sops/` sont stockées en clair dans ce dépôt.
> C'est acceptable pour un cluster de démonstration. En production, ces clés doivent être
> stockées de manière sécurisée (gestionnaire de secrets, HSM, CI/CD secrets) et **jamais committées**.

## 📚 Documentation détaillée

- [deploy/argocd/README.md](deploy/argocd/README.md) - Documentation technique complète
- [CLAUDE.md](CLAUDE.md) - Instructions pour Claude Code
- [vagrant/README.md](vagrant/README.md) - Documentation Vagrant/RKE2

## 🎓 Ressources ArgoCD

- [ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [Go Template Functions](https://pkg.go.dev/text/template)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
