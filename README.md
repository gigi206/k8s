# K8s + ArgoCD - Infrastructure GitOps

Infrastructure Kubernetes gérée via ArgoCD ApplicationSets avec templating Go natif.

## 🚀 Installation Complète (15 minutes)

```bash
./install-dev.sh
```

**C'est tout !** Ce script installe automatiquement :
- ✅ Cluster Kubernetes (RKE2) via Vagrant
- ✅ ArgoCD avec ApplicationSet controller
- ✅ 8 ApplicationSets qui génèrent 24 Applications (dev/local/prod)
- ✅ Applications essentielles : MetalLB, Cert-Manager, Ingress-NGINX, Longhorn, Prometheus, etc.

## 📝 Mise à jour des applications

Toute la configuration est dans Git. Pour modifier :

```bash
# 1. Modifier la configuration d'un environnement
vim argocd/config/environments/dev.yaml

# 2. Valider les changements
cd argocd && make validate

# 3. Committer et pusher
git add argocd/config/environments/dev.yaml
git commit -m "Update dev configuration"
git push

# 4. ArgoCD détecte et applique automatiquement (auto-sync activé en dev)
```

## 🔧 Commandes utiles

```bash
# Connexion au cluster
export KUBECONFIG=vagrant/.kube/config-dev
kubectl get nodes

# Voir les ApplicationSets (8)
kubectl get applicationsets -n argo-cd

# Voir les Applications générées (24: 8 apps × 3 environnements)
kubectl get applications -n argo-cd

# Surveiller le déploiement
cd argocd && make watch

# Accès ArgoCD UI
kubectl port-forward -n argo-cd svc/argocd-server 8080:443
# Login: admin
# Password: kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## 📁 Structure du projet

```
.
├── install-dev.sh                           # 🚀 Installation complète
├── Makefile                                 # Commandes alternatives
├── vagrant/                                 # Cluster Kubernetes (RKE2)
│   └── .kube/config-dev                    # Kubeconfig
└── argocd/
    ├── applicationsets/                     # 📦 ApplicationSets (un par app)
    │   ├── 00-argocd.yaml                  # Wave 0
    │   ├── 10-metallb.yaml                 # Wave 10
    │   ├── 20-cert-manager.yaml            # Wave 20
    │   ├── 30-external-dns.yaml            # Wave 30
    │   ├── 40-ingress-nginx.yaml           # Wave 40
    │   ├── 50-longhorn.yaml                # Wave 50
    │   ├── 60-prometheus-stack.yaml        # Wave 60
    │   └── 61-grafana-dashboards.yaml      # Wave 61
    │
    ├── config/                              # ⚙️ Configuration globale
    │   ├── common.yaml                     # Variables partagées
    │   └── environments/                    # Config par environnement
    │       ├── dev.yaml                    # Dev (8 apps actives)
    │       ├── local.yaml                  # Local (minimal)
    │       └── prod.yaml                   # Prod (8 apps avec 3 replicas)
    │
    └── applications/                        # 📄 Valeurs Helm par app
        ├── argocd/
        │   ├── values-base.yaml
        │   ├── values-dev.yaml
        │   └── values-prod.yaml
        ├── metallb/
        ├── cert-manager/
        └── ...
```

## 🎯 Environnements disponibles

| Env | Apps actives | Replicas | Auto-sync | Usage |
|-----|--------------|----------|-----------|-------|
| **dev** | 8 | 1 | ✅ | Développement rapide |
| **local** | 2 | 1 | ✅ | Tests locaux (kind/k3d) |
| **prod** | 8 | 3 | ❌ | Production (sync manuel) |

## 🏗️ Architecture ApplicationSet

```
ApplicationSets (8)
  └─> Lit config depuis Git
       └─> Génère Applications automatiquement
            └─> ArgoCD déploie avec auto-sync
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
# 1. Créer l'ApplicationSet
cp argocd/applicationsets/TEMPLATE.yaml argocd/applicationsets/70-my-app.yaml
vim argocd/applicationsets/70-my-app.yaml  # Adapter le template

# 2. Ajouter la config dans tous les environnements
vim argocd/config/environments/dev.yaml
vim argocd/config/environments/prod.yaml

# 3. Créer les values Helm (optionnel)
mkdir -p argocd/applications/my-app
touch argocd/applications/my-app/values-{base,dev,prod}.yaml

# 4. Committer et pusher
git add argocd/
git commit -m "Add my-app application"
git push

# 5. ArgoCD crée automatiquement les Applications
```

### Modifier une application existante

```bash
# Option 1: Modifier la config globale
vim argocd/config/environments/dev.yaml

# Option 2: Modifier les valeurs Helm
vim argocd/applications/my-app/values-dev.yaml

# Dans les deux cas, commit + push = déploiement auto
git add . && git commit -m "Update" && git push
```

## ❓ Dépannage

### Réinstaller proprement

```bash
cd vagrant && K8S_ENV=dev vagrant destroy -f && cd ..
./install-dev.sh
```

### Voir les logs ArgoCD

```bash
kubectl logs -n argo-cd deployment/argocd-server -f
kubectl logs -n argo-cd deployment/argocd-applicationset-controller -f
```

### Forcer un refresh

```bash
cd argocd && make refresh-all
```

### Statut des applications

```bash
cd argocd && make status
```

## 📌 Points importants

- **1 script d'installation** : `./install-dev.sh` fait tout
- **Configuration par environnement** : `argocd/config/environments/{env}.yaml`
- **ApplicationSets auto-générés** : Pas besoin de créer les Applications manuellement
- **Auto-sync en dev** : Les changements Git sont appliqués automatiquement
- **Sync manuel en prod** : Contrôle total sur les déploiements

## 📚 Documentation détaillée

- [argocd/README.md](argocd/README.md) - Documentation technique complète
- [CLAUDE.md](CLAUDE.md) - Instructions pour Claude Code
- [argocd/applicationsets/TEMPLATE.yaml](argocd/applicationsets/TEMPLATE.yaml) - Template pour nouvelles apps

## 🎓 Ressources ArgoCD

- [ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [Go Template Functions](https://pkg.go.dev/text/template)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
