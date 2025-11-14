# Cilium Monitoring

Cet ApplicationSet déploie les ServiceMonitors et PodMonitors pour les composants Cilium et Hubble afin d'activer la collecte de métriques Prometheus.

## Vue d'ensemble

Cilium est installé par RKE2 lors du bootstrap du cluster en tant que CNI (Container Network Interface). Le script d'installation RKE2 (`vagrant/scripts/configure_cilium.sh`) **désactive** intentionnellement tous les ServiceMonitors pour éviter les erreurs durant l'installation, puisque Prometheus n'est pas encore disponible à ce stade.

Une fois le cluster complètement bootstrappé et prometheus-stack déployé (Wave 75), cet ApplicationSet crée les ServiceMonitors et PodMonitors nécessaires pour activer le monitoring de Cilium et Hubble.

## Cilium en remplacement de kube-proxy

Dans ce cluster, Cilium est configuré avec `kubeProxyReplacement: true`, ce qui signifie que **kube-proxy n'est pas installé**. Cilium remplace complètement kube-proxy en utilisant eBPF pour gérer les services Kubernetes, le load balancing et les network policies.

**Impact sur le monitoring** :
- Le dashboard "Kubernetes / Proxy" dans Grafana sera vide (pas de métriques kube-proxy)
- Les métriques de load balancing sont disponibles dans les dashboards Cilium à la place
- C'est la configuration recommandée pour les déploiements Cilium en production

## Composants déployés

Cette application déploie :

### ServiceMonitors (3)

1. **hubble** - Monitore les métriques Hubble (requêtes DNS, flows, etc.)
2. **hubble-relay** - Monitore le service Hubble Relay (agrège les flows Hubble)
3. **cilium-envoy** - Monitore les métriques du proxy Envoy (proxy L7)

### PodMonitors (2)

1. **cilium-agent** - Monitore les métriques de l'agent Cilium (DaemonSet)
2. **cilium-operator** - Monitore les métriques de l'opérateur Cilium

**Note** : RKE2 n'installe pas Cilium avec des Services pour cilium-agent et cilium-operator. Les PodMonitors permettent de scraper directement les pods sans nécessiter de Services pour la découverte Kubernetes.

**Configuration des PodMonitors** :
- `cilium-agent` : Scrape le port `prometheus` (9962) des pods avec label `k8s-app=cilium`
- `cilium-operator` : Scrape le port `prometheus` (9963) des pods avec label `io.cilium/app=operator`

Les PodMonitors ajoutent automatiquement le label `k8s_app=cilium` requis par les dashboards officiels via `relabelings`.

Tous les ServiceMonitors et PodMonitors sont déployés dans le namespace `kube-system` avec le label `release: prometheus-stack` (injecté dynamiquement via Kustomize), qui est requis pour que Prometheus les découvre et les scrape.

### Dashboards Grafana (2)

1. **Cilium Agent Dashboard** - Métriques eBPF, load balancing des services, BPF maps, performance datapath
   - Affiche la fonctionnalité de remplacement de kube-proxy via eBPF
   - Métriques : santé des endpoints, connection tracking, application des policies, NAT/masquerading

2. **Cilium Operator Dashboard** - Statut de l'opérateur, allocation IP, réconciliation des endpoints
   - Affiche la gestion des adresses IP (IPAM), statut CiliumNode, utilisation des ressources de l'opérateur

Ces dashboards sont les **dashboards officiels Cilium** du chart Helm et remplacent la fonctionnalité du dashboard "Kubernetes / Proxy" désactivé. Ils sont automatiquement déployés via cet ApplicationSet (Wave 76) en utilisant des ConfigMaps avec le label `grafana_dashboard: "1"`.

## Déploiement

- **Wave** : 76 (après prometheus-stack en Wave 75)
- **Namespace** : kube-system (où tournent Cilium/Hubble)
- **Dépendances** : CRDs Prometheus Operator (depuis prometheus-stack)

## Dashboards Grafana

Une fois les métriques collectées, les dashboards Grafana suivants afficheront des données :

- **Hubble / DNS Overview (Namespace)** - Requêtes DNS, codes de réponse, latence
  - Nécessite : `dns:query;ignoreAAAA` dans la config des métriques Hubble
- **Hubble / HTTP Overview** - Taux de requêtes HTTP, codes de réponse, latence
  - Nécessite : CiliumNetworkPolicy avec règles L7 pour activer le proxy Envoy pour le trafic HTTP
  - Note : Sera vide sans policies L7 - les métriques HTTP ne sont générées que pour le trafic proxifié
- **Hubble / Flow Overview** - Flows réseau, paquets droppés, verdicts de policies
  - Toujours disponible - affiche tous les flows réseau
- **Cilium / Agent** - Santé de l'agent Cilium, utilisation des BPF maps, erreurs
  - Note : Métriques exposées sur les pods, nécessite PodMonitor (déployé dans cette ApplicationSet)
- **Cilium / Operator** - Statut de l'opérateur, réconciliation des endpoints
  - Note : Métriques exposées sur les pods, nécessite PodMonitor (déployé dans cette ApplicationSet)
- **Cilium / Envoy** - Métriques du proxy L7, statistiques de connexion
  - Disponible quand Envoy traite du trafic L7

## Métriques BPF Syscall (désactivées par défaut)

### Problème

Certains panels du dashboard "Cilium Metrics" affichent **"No data"**, notamment :
- **# system calls (average node)**
- **Average syscall duration**

### Cause racine

La métrique `cilium_bpf_syscall_duration_seconds` existe dans Cilium v1.18 mais est **désactivée par défaut** pour des raisons de performance.

**Statut des métriques BPF dans Cilium v1.18** :

| Métrique | Statut | Description |
|--------|--------|-------------|
| `cilium_bpf_map_ops_total` | ✅ Activée | Opérations sur les BPF maps (lookup, update, delete) |
| `cilium_bpf_map_pressure` | ✅ Activée | Ratio d'utilisation des BPF maps |
| `cilium_bpf_map_capacity` | ✅ Activée | Taille maximale des BPF maps |
| `cilium_bpf_maps_virtual_memory_max_bytes` | ✅ Activée | Mémoire utilisée par les BPF maps |
| `cilium_bpf_progs_virtual_memory_max_bytes` | ✅ Activée | Mémoire utilisée par les programmes BPF |
| `cilium_bpf_syscall_duration_seconds` | ❌ **Désactivée** | Durée des appels système BPF |

### Pourquoi désactivée ?

Les métriques syscall BPF tracent chaque appel système BPF (lookup, delete, update, objPin, getNextKey, etc.) avec le type d'opération et le résultat (success/failure). Cela introduit un **overhead de performance** sur cilium-agent, donc Cilium désactive ces métriques par défaut.

### Comment activer (si nécessaire)

Pour activer les métriques syscall, ajouter l'option `--metrics` au démarrage de cilium-agent :

**Option 1 : Via RKE2 HelmChartConfig** (recommandé pour RKE2) :

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: false  # Nous utilisons des PodMonitors à la place
      metrics:
        - "+cilium_bpf_syscall_duration_seconds"  # Activer les métriques syscall
```

**Option 2 : Via patch ConfigMap** :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  metrics: "+cilium_bpf_syscall_duration_seconds"
```

Après application, redémarrer les pods Cilium :
```bash
kubectl rollout restart daemonset/cilium -n kube-system
```

### Impact et recommandations

**Impact sur les performances** :
- Léger overhead CPU sur cilium-agent pour enregistrer les métriques syscall
- Mémoire additionnelle pour les buckets d'histogramme
- Plus de métriques stockées dans Prometheus

**Recommandations** :
- **Production** : Garder désactivé sauf en cas de debugging de problèmes spécifiques de performance BPF
- **Développement** : Peut être activé pour du profiling/debugging de performance syscall
- **Monitoring** : Utiliser `cilium_bpf_map_ops_total` à la place pour les performances générales des BPF maps

### Panels BPF fonctionnels

Ces panels fonctionnent correctement avec les métriques par défaut :
- **System-wide BPF memory usage** ✅
- **BPF map pressure** ✅
- **BPF map operations** ✅

## Configuration

Les valeurs du chart Helm Cilium sont gérées par RKE2 via le script `configure_cilium.sh`. Pour voir la configuration actuelle :

```bash
# Voir le HelmChartConfig
kubectl get helmchartconfig rke2-cilium -n kube-system -o yaml

# Voir les valeurs réellement appliquées à Cilium
kubectl get configmap -n kube-system rke2-cilium-config -o yaml
```

## Pourquoi séparé de l'installation RKE2 ?

Cilium est installé par RKE2 avant que prometheus-stack n'existe, donc les ServiceMonitors et dashboards Grafana ne peuvent pas être activés durant l'installation. Cet ApplicationSet fournit une solution GitOps propre pour activer le monitoring une fois que la stack de monitoring est prête.

Les dashboards Cilium Agent/Operator sont déployés via cet ApplicationSet plutôt que d'être activés dans le HelmChartConfig RKE2, car :
- Le HelmChartConfig de RKE2 ne se met pas à jour automatiquement après modification
- Les ConfigMaps de dashboards peuvent référencer une stack de monitoring qui n'existe pas encore durant le bootstrap du cluster
- GitOps via ArgoCD fournit un meilleur contrôle et une meilleure visibilité

**Note** : La configuration des dashboards est **commentée** dans `vagrant/scripts/configure_cilium.sh` (lignes 263 et 120) pour documenter que les dashboards peuvent être activés via le chart Helm, mais nous les déployons via cet ApplicationSet à la place pour de meilleures pratiques GitOps.

## Dépannage

### ServiceMonitors/PodMonitors non créés

Vérifier si l'Application existe et est synchronisée :

```bash
kubectl get application -n argo-cd cilium-monitoring
kubectl get application -n argo-cd cilium-monitoring -o yaml
```

### Métriques n'apparaissent pas dans Prometheus

Vérifier que les ServiceMonitors/PodMonitors ont le bon label :

```bash
kubectl get servicemonitor,podmonitor -n kube-system -l release=prometheus-stack
```

Vérifier si Prometheus scrape les targets :

```bash
# Port-forward vers Prometheus
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090

# Visiter http://localhost:9090/targets et chercher les targets cilium/hubble
```

### Dashboards affichant "No data"

Vérifier que les métriques sont disponibles dans Prometheus :

```bash
# Requête pour les métriques DNS Hubble
hubble_dns_queries_total

# Requête pour les métriques de flows Hubble
hubble_flows_processed_total

# Requête pour les métriques HTTP Hubble (sera vide sans policies L7)
hubble_http_requests_total

# Requête pour les métriques BPF Cilium
cilium_bpf_maps_virtual_memory_max_bytes
```

### Dashboard BPF affichant "No data"

**Problème** : Les panels "# system calls" et "Average syscall duration" affichent "No data".

**Cause** : Les métriques `cilium_bpf_syscall_duration_seconds` sont désactivées par défaut dans Cilium.

**Solution** : Voir la section "Métriques BPF Syscall (désactivées par défaut)" ci-dessus pour activer ces métriques si nécessaire.

**Note** : Les autres panels BPF (memory usage, map pressure, map operations) fonctionnent avec les métriques par défaut.

### Section kvstore affichant "No data"

**Problème** : La section "kvstore" du dashboard Cilium affiche "No data".

**Cause** : Cilium est configuré en mode `identity-allocation-mode: crd`, ce qui signifie qu'il utilise les Kubernetes CRDs pour le stockage d'état au lieu d'un kvstore externe (etcd/consul).

**Explication** :
- **Mode CRD** (configuration actuelle, recommandé pour single-cluster) :
  - Stockage d'état via Kubernetes CRDs
  - Pas de kvstore externe nécessaire
  - Métriques `kvstore_operations_total` non applicables
  - "No data" dans la section kvstore est **normal et attendu**

- **Mode kvstore** (non utilisé, requis pour multi-cluster) :
  - Nécessite etcd ou consul externe
  - Génère les métriques `kvstore_operations_total`
  - Permet le partage d'état entre clusters

**Vérification** :
```bash
# Vérifier le mode d'allocation d'identité
kubectl get configmap -n kube-system cilium-config -o jsonpath='{.data.identity-allocation-mode}'
# Output: crd
```

**Note** : Le mode CRD est la configuration recommandée pour les déploiements single-cluster. Les métriques kvstore ne sont pertinentes que pour les architectures multi-cluster avec kvstore externe.

### Section Service Updates (corrigée)

**Problème d'origine** : La section "Service Updates" du dashboard Cilium affichait "No data".

**Cause** : Le dashboard officiel Cilium utilisait la métrique `cilium_services_events_total` qui **n'existe pas** dans Cilium v1.18.1, bien qu'elle soit documentée dans la documentation officielle.

**Correction appliquée** : La requête du panel "Service Updates" a été mise à jour pour utiliser la métrique réellement disponible :
- **Avant** : `cilium_services_events_total{k8s_app="cilium", pod=~"$pod"}`
- **Après** : `cilium_kubernetes_events_total{k8s_app="cilium", pod=~"$pod", scope="Service"}`

**Vérification** :
```bash
# La métrique cilium_services_events_total n'existe pas
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090
# Dans Prometheus UI : cilium_services_events_total
# Résultat : 0 résultats

# La métrique cilium_kubernetes_events_total{scope="Service"} existe et contient les données
# Dans Prometheus UI : cilium_kubernetes_events_total{scope="Service"}
# Résultat : données disponibles (ex: action="update": 207)
```

**Note** : Les dashboards officiels Cilium du chart Helm ont été personnalisés pour corriger cette incohérence entre la documentation et l'implémentation réelle des métriques.

### Dashboard HTTP vide

**Problème** : Le dashboard "Hubble / HTTP Overview" n'affiche pas de données.

**Cause** : Les métriques HTTP L7 ne sont générées que lorsque le trafic passe par le proxy Envoy de Cilium, ce qui nécessite des CiliumNetworkPolicy avec règles L7.

**Solution** : Appliquer une CiliumNetworkPolicy pour activer la visibilité L7 pour vos services :

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: enable-http-visibility
  namespace: my-namespace
spec:
  endpointSelector:
    matchLabels:
      app: my-app
  ingress:
  - fromEndpoints:
    - {}
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "GET|POST|PUT|DELETE"
          path: "/"
```

Cette policy active le proxy Envoy pour le trafic HTTP sur le port 80, générant les métriques `hubble_http_*`.

**Note** : Les policies L7 ajoutent de la latence due à l'overhead du proxy. N'activer que pour les services où la visibilité est nécessaire.

### Prometheus ne découvre pas les PodMonitors

**Problème** : Les métriques Cilium Agent/Operator ne sont pas scrapées.

**Solution** : Redémarrer Prometheus pour forcer la découverte :

```bash
kubectl delete pod -n monitoring prometheus-xxx
```

Vérifier que le PodMonitor a le bon label `release: prometheus-stack`.

## Références

- [Cilium Observability Metrics](https://docs.cilium.io/en/stable/observability/metrics/)
- [Hubble Metrics](https://docs.cilium.io/en/stable/observability/metrics/#hubble-metrics)
- [Prometheus Operator ServiceMonitor](https://prometheus-operator.dev/docs/operator/design/#servicemonitor)
- [Prometheus Operator PodMonitor](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PodMonitor)
