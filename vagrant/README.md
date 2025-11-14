# Vagrant RKE2 Deployment

Déploiement automatisé de clusters Kubernetes RKE2 via Vagrant/Libvirt.

## 🚀 Démarrage Rapide

### Environnement DEV (1 master all-in-one)

```bash
# Depuis la racine du projet
make vagrant-dev-up

# Ou directement depuis vagrant/
cd vagrant
K8S_ENV=dev vagrant up
```

Le cluster est créé avec :
- 1 master (16 CPU, 32 GB RAM, 100 GB disk)
- RKE2 avec Cilium CNI
- LoadBalancer L2 configuré (192.168.121.200-250)

### Accéder au cluster

```bash
# SSH sur le master
make vagrant-dev-ssh

# Ou via kubectl depuis votre machine
export KUBECONFIG=$(pwd)/vagrant/kube.config
kubectl get nodes
```

### Déployer ArgoCD

ArgoCD n'est **pas** installé automatiquement. Pour le déployer :

```bash
# Depuis la racine du projet
export KUBECONFIG=$(pwd)/vagrant/kube.config
cd argocd
make dev
```

## 📁 Structure

```
vagrant/
├── Vagrantfile           # Vagrantfile principal (dynamique)
├── config/               # Configurations par environnement
│   ├── dev.rb           # Config dev (1 master all-in-one)
│   ├── staging.rb       # Config staging (3 masters)
│   └── prod.rb          # Config prod (3 masters + 3 workers)
├── scripts/              # Scripts d'installation RKE2
│   ├── RKE2_ENV.sh
│   ├── install_common.sh
│   ├── install_master.sh
│   ├── install_worker.sh
│   └── install_management.sh
└── README.md
```

## 🎯 Environnements Disponibles

### DEV (default)
- **Nœuds**: 1 master all-in-one
- **Ressources**: 16 CPU / 32 GB RAM / 100 GB disk
- **Usage**: Développement local

```bash
make vagrant-dev-up
```

### STAGING
- **Nœuds**: 3 masters (pas de workers dédiés)
- **Ressources**: 8 CPU / 16 GB RAM / 50 GB disk par nœud
- **Usage**: Tests d'intégration

```bash
make vagrant-staging-up
```

### PROD
- **Nœuds**: 3 masters + 3 workers
- **Ressources**:
  - Masters: 8 CPU / 16 GB RAM / 50 GB disk
  - Workers: 8 CPU / 16 GB RAM / 100 GB disk
- **Usage**: Production ou simulation production

```bash
make vagrant-prod-up
```

## 🛠️ Commandes Disponibles

### Depuis la racine (Makefile)

```bash
# DEV
make vagrant-dev-up              # Créer et démarrer
make vagrant-dev-status          # Statut
make vagrant-dev-ssh             # SSH sur le master
make vagrant-dev-down            # Arrêter
make vagrant-dev-destroy         # Détruire

# STAGING
make vagrant-staging-up
make vagrant-staging-status
make vagrant-staging-down
make vagrant-staging-destroy

# PROD
make vagrant-prod-up
make vagrant-prod-status
make vagrant-prod-down
make vagrant-prod-destroy

# Nettoyage
make clean-all                   # Supprimer tout
```

### Depuis vagrant/ (commandes Vagrant natives)

```bash
cd vagrant

# Définir l'environnement
export K8S_ENV=dev  # ou staging, prod

# Commandes Vagrant
vagrant up              # Créer/démarrer
vagrant status          # Statut
vagrant ssh <nom>       # SSH
vagrant halt            # Arrêter
vagrant destroy         # Détruire
vagrant provision       # Re-provisionner

# Exemples
K8S_ENV=dev vagrant up
K8S_ENV=prod vagrant status
K8S_ENV=dev vagrant ssh k8s-dev-m1
```

## 🔧 Configuration

### Personnaliser un environnement

Éditez le fichier de configuration correspondant :

```ruby
# config/dev.rb
$vm_box = "debian/trixie64"
$masters = 1
$master_cpu = 16
$master_memory = 32768
$master_disk = 100
```

### Créer un nouvel environnement

1. Créer `config/custom.rb` avec votre configuration
2. Lancer avec `K8S_ENV=custom vagrant up`

### Déployer ArgoCD après création

```bash
# Une fois le cluster créé
export KUBECONFIG=$(pwd)/../vagrant/kube.config
cd ../argocd
make dev  # ou make prod selon l'environnement
```

## 📊 Composants Installés

### Sur tous les nœuds
- Debian Trixie
- RKE2
- Cilium CNI (avec kube-proxy replacement)
- Open-iSCSI + NFS (pour Longhorn)
- Homebrew + outils CLI (helm, kubectl plugins, etc.)

### Sur le premier master
- Kubeconfig exporté vers `/vagrant/kube.config`
- Token RKE2 pour jointure des autres nœuds

### Configuration Cilium
- **kube-proxy replacement**: ✅ Activé
- **L2 announcements**: ✅ (LoadBalancer IPs)
- **IP Pool**: 192.168.121.200-250
- **Hubble UI**: ✅ (hubble.gigix)
- **Monitoring**: ✅ (Prometheus/Grafana ready)

## 🌐 Accès aux Services

### API Kubernetes
- **IP LB**: 192.168.121.200
- **Hostname**: k8s-api.gigix
- **Port**: 443

### ArgoCD UI (si déployé manuellement)
- **IP**: Assignée par Cilium LoadBalancer
- **Type**: Selon votre configuration ArgoCD
- **Login**: admin
- **Password**: `kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

### Hubble UI
- **Hostname**: hubble.gigix
- **Type**: HTTPS avec cert auto-signé

## 🔍 Troubleshooting

### Vérifier l'état du cluster

```bash
# Nœuds
kubectl get nodes

# Pods système
kubectl get pods -A

# ArgoCD apps
kubectl get app -n argo-cd

# Cilium
kubectl get pods -n kube-system -l k8s-app=cilium
```

### Logs du bootstrap

```bash
vagrant ssh k8s-dev-m1
sudo journalctl -u rke2-server -f
```

### Réinstaller sans détruire les VMs

```bash
K8S_ENV=dev vagrant provision
```

### Problème de réseau

Vérifier Cilium :
```bash
kubectl -n kube-system exec -it ds/cilium -- cilium status
kubectl -n kube-system exec -it ds/cilium -- cilium connectivity test
```

## 📝 Notes

### Réseau
- **Network**: 192.168.121.0/24 (vagrant-libvirt default)
- **Masters**: .11, .12, .13
- **Workers**: .101, .102, .103
- **Management**: .10 (si activé)
- **LoadBalancer Pool**: .200-.250

### DNS
- **Domaine**: gigix
- **External-DNS**: Configuré pour PowerDNS
- **CoreDNS**: Par défaut RKE2

### Stockage
- **Longhorn**: Disponible dans ArgoCD apps
- **local-path**: Désactivé (Longhorn préféré)

### Fichiers générés
Fichiers générés dans `vagrant/` :
- `kube.config` - Kubeconfig pour accès kubectl
- `k8s-token` - Token RKE2 pour jointure des nœuds
- `ip_master` - IP du premier master

## 🔗 Liens

- [RKE2 Documentation](https://docs.rke2.io/)
- [Cilium Documentation](https://docs.cilium.io/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Vagrant Libvirt](https://github.com/vagrant-libvirt/vagrant-libvirt)
