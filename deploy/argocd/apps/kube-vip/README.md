# Kube-VIP

Kube-VIP fournit une VIP (Virtual IP) hautement disponible pour l'API Kubernetes.

## Description

Kube-VIP permet d'accéder à l'API Kubernetes via une adresse IP virtuelle flottante qui bascule automatiquement entre les nœuds master en cas de défaillance.

## Configuration

### Configuration dev (config/dev.yaml)

```yaml
environment: dev
appName: kube-vip

kubeVip:
  vip: "192.168.121.200"        # VIP pour l'API Kubernetes
  interface: "eth1"              # Interface réseau
  arpEnabled: true               # Utilise ARP pour annoncer la VIP

syncPolicy:
  automated:
    enabled: true
    prune: true
    selfHeal: true
```

### Configuration prod (config/prod.yaml)

Similaire à dev, mais avec `automated.enabled: false` pour contrôle manuel.

## Ressources déployées (resources/)

- **rbac.yaml**: ServiceAccount, ClusterRole, ClusterRoleBinding
- **daemonset.yaml**: DaemonSet kube-vip sur les nœuds master

## Vérification

```bash
# Vérifier le DaemonSet
kubectl get daemonset -n kube-system kube-vip

# Vérifier la VIP configurée
kubectl get daemonset kube-vip -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="address")].value}'

# Tester l'accès à la VIP
curl -k https://192.168.121.200:6443/version
```

## Kubeconfig

Le script `deploy-applicationsets.sh` met automatiquement à jour votre kubeconfig pour utiliser la VIP au lieu de l'IP d'un nœud spécifique :

```bash
# Avant: https://192.168.121.11:6443
# Après: https://192.168.121.200:6443 (VIP)
```

## Documentation

- [Kube-VIP Documentation](https://kube-vip.io/)
- [Kube-VIP GitHub](https://github.com/kube-vip/kube-vip)

## Notes

- Wave 15 (déployé après MetalLB, avant Cert-Manager)
- Utilise ARP pour annoncer la VIP sur le réseau local
- Le DaemonSet s'exécute sur les nœuds master uniquement (nodeSelector)
- Nécessite l'interface réseau `eth1` (interface Vagrant)
