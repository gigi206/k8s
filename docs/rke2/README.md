# RKE2 - Rancher Kubernetes Engine 2

RKE2 est la distribution Kubernetes de Rancher, optimisée pour la sécurité et la conformité.

## Configuration

### Fichiers de configuration

| Fichier | Description |
|---------|-------------|
| `/etc/rancher/rke2/config.yaml` | Configuration principale RKE2 |
| `/etc/rancher/rke2/config.yaml.d/*.yaml` | Configurations additionnelles (drop-in) |
| `/etc/rancher/rke2/rke2.yaml` | Kubeconfig généré |
| `/var/lib/rancher/rke2/server/token` | Token pour joindre les nodes |

### Configuration actuelle

Ce projet configure RKE2 avec les options suivantes :

```yaml
# Composants désactivés
disable:
  - rke2-ingress-nginx    # Remplacé par ingress-nginx via ArgoCD
  - rke2-kube-proxy       # Remplacé par Cilium eBPF
  - rke2-canal            # Remplacé par Cilium CNI

# Cilium en remplacement de kube-proxy
disable-kube-proxy: true
cni:
  - cilium

# TLS SANs pour l'API
tls-san:
  - k8s-api.k8s.lan
  - 192.168.121.200

# Métriques
etcd-expose-metrics: true
kube-controller-manager-arg:
  - bind-address=0.0.0.0
kube-scheduler-arg:
  - bind-address=0.0.0.0
```

## Architecture

### Composants serveur (master)

- **kube-apiserver**: API Kubernetes
- **kube-controller-manager**: Controllers intégrés
- **kube-scheduler**: Planification des pods
- **etcd**: Base de données du cluster
- **kubelet**: Agent de node
- **containerd**: Runtime de conteneurs

### Composants agent (worker)

- **kubelet**: Agent de node
- **containerd**: Runtime de conteneurs
- **kube-proxy**: Désactivé (Cilium eBPF)

## Commandes utiles

### Gestion du service

```bash
# Serveur (master)
sudo systemctl status rke2-server
sudo systemctl restart rke2-server
sudo journalctl -u rke2-server -f

# Agent (worker)
sudo systemctl status rke2-agent
sudo systemctl restart rke2-agent
sudo journalctl -u rke2-agent -f
```

### Kubectl et outils

```bash
# Configuration kubectl
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="${PATH}:/var/lib/rancher/rke2/bin"

# Ou pour l'utilisateur vagrant
export KUBECONFIG=/vagrant/kube.config

# Vérifier le cluster
kubectl get nodes
kubectl get pods -A
```

### Containerd (crictl)

```bash
# Configurer crictl
crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock

# Lister les conteneurs
crictl ps

# Lister les images
crictl images

# Logs d'un conteneur
crictl logs <container-id>
```

### etcd

```bash
# Snapshot etcd
rke2 etcd-snapshot save --name my-snapshot

# Lister les snapshots
rke2 etcd-snapshot ls

# Restaurer un snapshot
rke2 etcd-snapshot restore my-snapshot
```

## Troubleshooting

### Node ne rejoint pas le cluster

```bash
# Vérifier la connectivité vers le master
curl -k https://<master-ip>:9345/cacerts

# Vérifier le token
cat /var/lib/rancher/rke2/server/token

# Logs de l'agent
sudo journalctl -u rke2-agent -f
```

### API server inaccessible

```bash
# Vérifier le service
sudo systemctl status rke2-server

# Vérifier le port
ss -tlnp | grep 6443

# Vérifier les certificats
openssl s_client -connect localhost:6443 </dev/null 2>/dev/null | openssl x509 -noout -dates
```

### Pods en Pending (CNI)

```bash
# Vérifier Cilium
kubectl get pods -n kube-system -l k8s-app=cilium

# Logs Cilium
kubectl logs -n kube-system -l k8s-app=cilium

# Status Cilium
kubectl -n kube-system exec -it ds/cilium -- cilium status
```

### etcd problèmes

```bash
# Health check etcd
kubectl get componentstatus

# Logs etcd
sudo journalctl -u rke2-server | grep etcd

# Vérifier l'espace disque
df -h /var/lib/rancher/rke2/server/db/etcd
```

## Chemins importants

| Chemin | Description |
|--------|-------------|
| `/var/lib/rancher/rke2/` | Données RKE2 |
| `/var/lib/rancher/rke2/bin/` | Binaires (kubectl, crictl) |
| `/var/lib/rancher/rke2/server/db/etcd/` | Données etcd |
| `/var/lib/rancher/rke2/server/manifests/` | Manifests statiques |
| `/var/lib/rancher/rke2/agent/logs/` | Logs kubelet |
| `/var/log/pods/` | Logs des pods |

## Références

- [RKE2 Documentation](https://docs.rke2.io/)
- [RKE2 Configuration Options](https://docs.rke2.io/reference/server_config)
- [RKE2 Network Options](https://docs.rke2.io/install/network_options)
- [Cilium with RKE2](https://docs.rke2.io/install/network_options#cilium)
