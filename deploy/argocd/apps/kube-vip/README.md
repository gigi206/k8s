# Kube-VIP

Kube-VIP fournit une VIP (Virtual IP) hautement disponible pour l'API Kubernetes.

## Description

Kube-VIP permet d'accéder à l'API Kubernetes via une adresse IP virtuelle flottante qui bascule automatiquement entre les nœuds master en cas de défaillance.

## Configuration

### VIP centralisée (config/config.yaml)

La VIP est définie dans la configuration globale :

```yaml
features:
  loadBalancer:
    staticIPs:
      kubernetesApi: "192.168.121.200"   # Kubernetes API VIP (kube-vip)
```

### Configuration dev (config/dev.yaml)

```yaml
environment: dev
appName: kube-vip

kubeVip:
  version: "v1.0.3"
  interface: "eth1"              # Interface réseau
  arp: true                      # Utilise ARP pour annoncer la VIP

syncPolicy:
  automated:
    enabled: true
    prune: true
    selfHeal: true
```

### Configuration prod (config/prod.yaml)

Similaire à dev, mais avec `automated.enabled: false` pour contrôle manuel.

## Ressources déployées

- **resources/rbac.yaml**: ServiceAccount, ClusterRole, ClusterRoleBinding
- **kustomize/daemonset/daemonset.yaml**: DaemonSet kube-vip sur les nœuds master (VIP injectée via kustomize patch)

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

## Monitoring

### Prometheus Alerts

3 alertes sont configurées pour surveiller Kube-VIP via kube-state-metrics :

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| KubeVIPDaemonSetNotReady | critical | DaemonSet n'a pas tous les pods ready (5m) |
| KubeVIPPodCrashLooping | critical | Pod en restart loop (10m) |
| KubeVIPPodNotRunning | critical | Pod n'est pas en état Running (5m) |

**Note** : Kube-VIP n'expose pas de métriques Prometheus natives. Les alertes utilisent kube-state-metrics pour surveiller le DaemonSet.

## Troubleshooting

### VIP inaccessible

```bash
# Vérifier les pods kube-vip
kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-vip

# Logs du pod
kubectl logs -n kube-system -l app.kubernetes.io/name=kube-vip

# Vérifier que la VIP est bien annoncée (ARP)
arping -c 3 192.168.121.200
```

### Pod ne démarre pas

```bash
# Vérifier les events
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep kube-vip

# Vérifier les tolérances (doit tolérer master taints)
kubectl describe daemonset -n kube-system kube-vip | grep -A5 Tolerations
```

### VIP non attribuée au bon node

```bash
# Identifier le leader actuel
kubectl logs -n kube-system -l app.kubernetes.io/name=kube-vip | grep -i leader

# Vérifier l'interface réseau configurée
kubectl get daemonset kube-vip -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="vip_interface")].value}'
```

### Kubeconfig ne fonctionne pas avec la VIP

```bash
# Vérifier que kubectl pointe vers la VIP
grep server ~/.kube/config

# Tester la connexion
curl -k https://192.168.121.200:6443/version

# Mettre à jour le kubeconfig si nécessaire
kubectl config set-cluster kubernetes --server=https://192.168.121.200:6443
```

## Documentation

- [Kube-VIP Documentation](https://kube-vip.io/)
- [Kube-VIP GitHub](https://github.com/kube-vip/kube-vip)

## Notes

-  (déployé après MetalLB, avant Cert-Manager)
- Utilise ARP pour annoncer la VIP sur le réseau local
- Le DaemonSet s'exécute sur les nœuds master uniquement (nodeSelector)
- Nécessite l'interface réseau `eth1` (interface Vagrant)
