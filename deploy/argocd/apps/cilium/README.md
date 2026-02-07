# Cilium

Cet ApplicationSet gère les ressources additionnelles pour Cilium CNI, incluant le monitoring Prometheus et les network policies cluster-wide.

## Vue d'ensemble

**Cilium est installé par RKE2** lors du bootstrap du cluster en tant que CNI (Container Network Interface). Le script d'installation RKE2 (`vagrant/scripts/configure_cilium.sh`) configure Cilium avec les options suivantes :

- `kubeProxyReplacement: true` - Cilium remplace kube-proxy via eBPF
- `routingMode: native` - Routage direct sans tunneling
- `l7Proxy: true` - Proxy L7 Envoy activé
- `hostFirewall: enabled` - Firewall au niveau host
- `hubble.enabled: true` - Observabilité réseau via Hubble

**Cet ApplicationSet déploie des ressources additionnelles :**

1. **Monitoring** - ServiceMonitors, PodMonitors et dashboards Grafana pour Prometheus
2. **Network Policies** - CiliumClusterwideNetworkPolicy pour le contrôle du trafic egress
3. **HTTPRoute** - Accès à l'UI Hubble via Gateway API (optionnel)
4. **LB-IPAM** - CiliumLoadBalancerIPPool et CiliumL2AnnouncementPolicy (si `loadBalancer.provider=cilium`)

## LoadBalancer Provider (LB-IPAM)

### Configuration

Le provider LoadBalancer est configurable dans `config.yaml` :

```yaml
features:
  loadBalancer:
    enabled: true
    provider: "metallb"  # metallb | cilium
    pools:
      default:
        range: "192.168.121.201-192.168.121.250"
```

- **`metallb`** (défaut) : MetalLB gère les IPs LoadBalancer via L2 announcements
- **`cilium`** : Cilium LB-IPAM avec CiliumLoadBalancerIPPool et CiliumL2AnnouncementPolicy

### Configuration requise : Interface L2 dans les devices Cilium

> **⚠️ IMPORTANT** : L'interface utilisée dans `CiliumL2AnnouncementPolicy` **DOIT** être dans la liste des devices gérés par Cilium. Sinon, les programmes BPF ne seront pas attachés et les réponses ARP ne fonctionneront pas.

**Symptômes si mal configuré** :
- Les IPs LoadBalancer sont assignées aux services
- Les leases L2 sont acquises correctement
- La map BPF `cilium_l2_responder_v4` est **vide** (0 éléments)
- Aucune réponse ARP n'est envoyée
- Ping échoue avec "Time to live exceeded" ou "Destination Host Unreachable"

**Vérification** :
```bash
# Voir les devices gérés par Cilium
kubectl -n kube-system get cm cilium-config -o yaml | grep devices

# Voir l'interface configurée dans la policy L2
kubectl get ciliuml2announcementpolicy -o yaml | grep -A2 interfaces

# Vérifier si la map BPF est remplie (doit contenir les IPs LB)
kubectl -n kube-system exec ds/cilium -- bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_l2_responder_v4
```

**Solution** : L'interface dans `CiliumL2AnnouncementPolicy` doit correspondre à un device dans `cilium-config` :
```yaml
# cilium-config
devices: eth0

# CiliumL2AnnouncementPolicy - DOIT utiliser eth0
spec:
  interfaces:
    - eth0  # ✓ Correct - eth0 est dans devices
    # - eth1  # ✗ Incorrect - eth1 n'est pas dans devices
```

**Note** : Cilium L2 fonctionne sur les VMs (virtio/KVM) quand l'interface est correctement configurée.

## Network Policies

### Feature Flags

Les network policies sont contrôlées par les feature flags dans `config.yaml` :

```yaml
features:
  cilium:
    monitoring:
      enabled: true       # : ServiceMonitors, dashboards Grafana
    egressPolicy:
      enabled: true       # CiliumClusterwideNetworkPolicy default-deny egress + per-app policies
    ingressPolicy:
      enabled: true       # CiliumClusterwideNetworkPolicy default-deny host ingress (SSH, API, HTTP/HTTPS)
```

Les policies ne sont déployées que si `features.cilium.egressPolicy.enabled == true` OU `features.cilium.ingressPolicy.enabled == true`.

### Architecture

La politique réseau suit le principe **default-deny avec exceptions par application** :

#### Egress Policies (pods → external)

1. **`cilium/resources/default-deny-external-egress.yaml`** - Bloque TOUT le trafic externe (cluster-wide)
2. **Chaque application** définit sa propre `CiliumNetworkPolicy` dans son répertoire `resources/`

```
cilium/
└── resources/default-deny-external-egress.yaml   # Bloque tout (cluster-wide)

argocd/
└── resources/cilium-egress-policy.yaml           # Autorise egress argo-cd

neuvector/
└── resources/cilium-egress-policy.yaml           # Autorise egress neuvector

cert-manager/
└── resources/cilium-egress-policy.yaml           # Autorise egress cert-manager (ACME)
```

#### Host Firewall Policies (external → nodes)

1. **`cilium/resources/default-deny-host-ingress.yaml`** - Protège les nœuds Kubernetes (policy globale)
2. **Per-app policies** - Chaque application exposant un LoadBalancer définit ses ports

**Ports autorisés par la policy globale :**

| Port | Protocol | Description |
|------|----------|-------------|
| 22 | TCP | SSH (administration) |
| 6443 | TCP | Kubernetes API |
| ICMP type 8 | - | Echo Request (ping) |
| Cluster interne | All | Trafic cluster (pods, services, nodes) |

**Ports définis par application (per-app policies) :**

| Application | Fichier | Ports | Node Label |
|-------------|---------|-------|------------|
| istio-gateway | `resources/cilium-host-ingress-policy.yaml` | 80, 443 TCP | `node-role.kubernetes.io/ingress` |
| ingress-nginx | `resources/cilium-host-ingress-policy.yaml` | 80, 443 TCP | `node-role.kubernetes.io/ingress` |
| traefik | `resources/cilium-host-ingress-policy.yaml` | 80, 443 TCP | `node-role.kubernetes.io/ingress` |
| apisix | `resources/cilium-host-ingress-policy.yaml` | 80, 443 TCP | `node-role.kubernetes.io/ingress` |
| envoy-gateway | `resources/cilium-host-ingress-policy.yaml` | 80, 443 TCP | `node-role.kubernetes.io/ingress` |
| nginx-gateway-fabric | `resources/cilium-host-ingress-policy.yaml` | 80, 443 TCP | `node-role.kubernetes.io/ingress` |
| external-dns | `resources/cilium-host-ingress-policy.yaml` | 53 TCP/UDP | `node-role.kubernetes.io/dns` |

**Trafic bloqué :**
- Tous les autres ports depuis l'extérieur (etcd 2379, kubelet 10250, etc.)

**Ciblage des nœuds :**
```bash
# Labéliser les workers pour les ingress controllers
kubectl label node <worker-node> node-role.kubernetes.io/ingress=""

# Labéliser les nodes pour external-dns
kubectl label node <node> node-role.kubernetes.io/dns=""
```

Pour un ciblage plus précis, utilisez `externalTrafficPolicy: Local` sur les LoadBalancer services.

### Politique par défaut (default-deny)

La `CiliumClusterwideNetworkPolicy` bloque tout le trafic sortant vers l'extérieur (`world`) sauf DNS.

**Trafic toujours autorisé (pour tous les namespaces) :**

- Cluster interne (pod-to-pod, services) via `toEntities: cluster`
- DNS interne (kube-dns sur port 53)
- DNS externe (port 53 vers `world`) - requis pour résoudre les domaines externes
- API Kubernetes via `toEntities: kube-apiserver`
- Node-local via `toEntities: host`

**Trafic bloqué :**

- Tout autre trafic vers `world` (HTTPS, HTTP, SSH, etc.)

### Applications avec accès externe

| Application | Fichier | Ports autorisés |
|-------------|---------|-----------------|
| ArgoCD | `argocd/resources/cilium-egress-policy.yaml` | 443/TCP (HTTPS), 22/TCP (SSH) |
| NeuVector | `neuvector/resources/cilium-egress-policy.yaml` | 443/TCP (HTTPS) |
| cert-manager | `cert-manager/resources/cilium-egress-policy.yaml` | 443/TCP (ACME) |

### Ajouter une application à la whitelist

1. Créer le fichier `cilium-egress-policy.yaml` dans le répertoire `resources/` de l'application :

```yaml
# deploy/argocd/apps/mon-app/resources/cilium-egress-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: mon-app-allow-external-egress
  namespace: mon-namespace
spec:
  description: "Allow mon-app to access external services"
  endpointSelector: {}
  egress:
   - toEntities:
       - world
      toPorts:
       - ports:
           - port: "443"
              protocol: TCP
```

2. Ajouter la source conditionnelle dans l'ApplicationSet de l'application (`templatePatch.sources`) :

```yaml
{{- if .features.cilium.egressPolicy.enabled }}
# Source: Cilium egress policy - conditional
- repoURL: https://github.com/gigi206/k8s
  targetRevision: '{{ .git.revision }}'
  path: deploy/argocd/apps/mon-app/resources
  directory:
    include: "cilium-egress-policy.yaml"
{{- end }}
```

**Note** : On utilise `directory: include:` pour charger uniquement le fichier network-policy
de manière conditionnelle, sans affecter les autres ressources du répertoire `resources/`.

### Vérifier le blocage egress

```bash
# Vérifier les policies
kubectl get ciliumclusterwidenetworkpolicies
kubectl get ciliumnetworkpolicies -A

# Test depuis un namespace bloqué (doit timeout)
kubectl exec -n monitoring deploy/prometheus-stack-grafana -- \
  curl -s --connect-timeout 5 https://example.com

# Test depuis un namespace autorisé (doit fonctionner)
kubectl exec -n argo-cd deploy/argocd-repo-server -- \
  curl -s https://github.com

# Observer les drops via Hubble
kubectl exec -n kube-system ds/cilium -- \
  cilium hubble observe --verdict DROPPED --type drop

# Observer les drops en temps réel
kubectl exec -n kube-system ds/cilium -- \
  cilium hubble observe --verdict DROPPED --reason POLICY_DENIED -f
```

### Vérifier le Host Firewall

```bash
# Vérifier que la policy host est appliquée
kubectl get ciliumclusterwidenetworkpolicies | grep host

# Vérifier le statut du host endpoint
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $CILIUM_POD -- cilium-dbg endpoint list | grep reserved:host

# Test depuis l'extérieur du cluster (sur la machine hôte)
NODE_IP=<ip-du-noeud>
curl -k https://$NODE_IP:6443/healthz      # Doit fonctionner (API K8s)
curl http://$NODE_IP:80                     # Doit fonctionner (ingress)
curl http://$NODE_IP:2379                   # Doit être bloqué (etcd)
nc -zv $NODE_IP 10250                       # Doit être bloqué (kubelet)

# Surveiller les policy verdicts host
kubectl -n kube-system exec $CILIUM_POD -- \
  cilium-dbg monitor -t policy-verdict --related-to 1
```

### Désactiver / Rollback

**Option 1 : Via feature flag (recommandé)**

Mettre `features.cilium.egressPolicy.enabled: false` dans `config.yaml`, puis synchroniser ArgoCD.
Les policies seront automatiquement supprimées (prune).

**Option 2 : Suppression manuelle**

```bash
# Supprimer la policy globale (autorise tout)
kubectl delete ciliumclusterwidenetworkpolicy default-deny-external-egress

# Ou supprimer une policy spécifique
kubectl delete ciliumnetworkpolicy -n argo-cd argocd-allow-external-egress
```

## Monitoring

### Cilium en remplacement de kube-proxy

Dans ce cluster, Cilium est configuré avec `kubeProxyReplacement: true`, ce qui signifie que **kube-proxy n'est pas installé**. Cilium remplace complètement kube-proxy en utilisant eBPF pour gérer les services Kubernetes, le load balancing et les network policies.

**Impact sur le monitoring** :
- Le dashboard "Kubernetes / Proxy" dans Grafana sera vide (pas de métriques kube-proxy)
- Les métriques de load balancing sont disponibles dans les dashboards Cilium à la place
- C'est la configuration recommandée pour les déploiements Cilium en production

### Composants déployés

Cette application déploie :

#### ServiceMonitors (3)

1. **hubble** - Monitore les métriques Hubble (requêtes DNS, flows, etc.)
2. **hubble-relay** - Monitore le service Hubble Relay (agrège les flows Hubble)
3. **cilium-envoy** - Monitore les métriques du proxy Envoy (proxy L7)

#### PodMonitors (2)

1. **cilium-agent** - Monitore les métriques de l'agent Cilium (DaemonSet)
2. **cilium-operator** - Monitore les métriques de l'opérateur Cilium

**Note** : RKE2 n'installe pas Cilium avec des Services pour cilium-agent et cilium-operator. Les PodMonitors permettent de scraper directement les pods sans nécessiter de Services pour la découverte Kubernetes.

**Configuration des PodMonitors** :
- `cilium-agent` : Scrape le port `prometheus` (9962) des pods avec label `k8s-app=cilium`
- `cilium-operator` : Scrape le port `prometheus` (9963) des pods avec label `io.cilium/app=operator`

Les PodMonitors ajoutent automatiquement le label `k8s_app=cilium` requis par les dashboards officiels via `relabelings`.

Tous les ServiceMonitors et PodMonitors sont déployés dans le namespace `kube-system` avec le label `release: prometheus-stack` (injecté dynamiquement via Kustomize), qui est requis pour que Prometheus les découvre et les scrape.

#### Dashboards Grafana (2)

1. **Cilium Agent Dashboard** - Métriques eBPF, load balancing des services, BPF maps, performance datapath
  - Affiche la fonctionnalité de remplacement de kube-proxy via eBPF
  - Métriques : santé des endpoints, connection tracking, application des policies, NAT/masquerading

2. **Cilium Operator Dashboard** - Statut de l'opérateur, allocation IP, réconciliation des endpoints
  - Affiche la gestion des adresses IP (IPAM), statut CiliumNode, utilisation des ressources de l'opérateur

Ces dashboards sont les **dashboards officiels Cilium** du chart Helm et remplacent la fonctionnalité du dashboard "Kubernetes / Proxy" désactivé. Ils sont automatiquement déployés via cet ApplicationSet en utilisant des ConfigMaps avec le label `grafana_dashboard: "1"`.

## Déploiement

- **Wave** : 76 (après prometheus-stack en )
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
| `cilium_bpf_map_ops_total` | Activée | Opérations sur les BPF maps (lookup, update, delete) |
| `cilium_bpf_map_pressure` | Activée | Ratio d'utilisation des BPF maps |
| `cilium_bpf_map_capacity` | Activée | Taille maximale des BPF maps |
| `cilium_bpf_maps_virtual_memory_max_bytes` | Activée | Mémoire utilisée par les BPF maps |
| `cilium_bpf_progs_virtual_memory_max_bytes` | Activée | Mémoire utilisée par les programmes BPF |
| `cilium_bpf_syscall_duration_seconds` | **Désactivée** | Durée des appels système BPF |

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
- **System-wide BPF memory usage**
- **BPF map pressure**
- **BPF map operations**

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

### Diagnostiquer les drops avec Hubble

**Lorsque des connexions échouent** (timeout, connection refused), utilisez Hubble pour identifier les paquets bloqués par les network policies :

```bash
# Voir les 50 derniers paquets droppés
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --last 50

# Suivre les drops en temps réel
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED -f

# Filtrer par namespace source
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --from-namespace argo-cd

# Filtrer par namespace destination
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --to-namespace keycloak

# Voir uniquement les drops de policy (pas les erreurs réseau)
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --type policy-verdict
```

**Exemple de sortie Hubble :**
```
Dec 20 16:07:20.543: monitoring/prometheus-0:58092 <> rook-ceph/exporter:9926 Policy denied DROPPED (TCP Flags: SYN)
                     ^^^^^^^^^^^^^^^^^^^^^^^^        ^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^
                     Source (namespace/pod:port)     Destination             Raison du drop
```

**Actions correctives :**

1. Identifier le namespace source et destination
2. Vérifier si une `CiliumNetworkPolicy` existe pour le namespace destination
3. Ajouter le port manquant dans la section `ingress` de la policy

**Exemple de correction :**
```yaml
# Dans apps/<app>/resources/cilium-ingress-policy.yaml
ingress:
 - fromEndpoints:
     - matchLabels:
          io.kubernetes.pod.namespace: monitoring  # Autoriser depuis monitoring
    toPorts:
     - ports:
         - port: "9926"  # Port manquant identifié via Hubble
            protocol: TCP
```

### ServiceMonitors/PodMonitors non créés

Vérifier si l'Application existe et est synchronisée :

```bash
kubectl get application -n argo-cd cilium
kubectl get application -n argo-cd cilium -o yaml
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

### Network Policy ne bloque pas le trafic

**Problème** : Le trafic externe n'est pas bloqué malgré la policy.

**Vérification** :

```bash
# Vérifier que la policy est créée
kubectl get ciliumclusterwidenetworkpolicies

# Vérifier le statut de la policy
kubectl describe ciliumclusterwidenetworkpolicy default-deny-external-egress

# Observer les flows avec Hubble
kubectl exec -n kube-system ds/cilium -- \
  cilium hubble observe --type policy-verdict -f
```

**Causes possibles** :
- Le namespace a une `CiliumNetworkPolicy` qui autorise le trafic (voir section "Applications avec accès externe")
- Le trafic est vers une destination interne au cluster (toEntities: cluster)
- Le trafic est du DNS (port 53, autorisé pour le forwarding)
- La policy n'est pas encore synchronisée par ArgoCD
- Le feature flag `features.cilium.egressPolicy.enabled` est désactivé

## Stockage SPIRE (Mutual Authentication)

### Problème Chicken-and-Egg

SPIRE Server a besoin d'un PVC pour persister ses données (identités, bundles), mais au bootstrap RKE2 :
- SPIRE boot **avant** le storage provider (Rook/Longhorn)
- Le storage provider est déployé **via ArgoCD**, qui s'installe après Cilium
- Aucun StorageClass n'existe encore quand Cilium démarre

### Solution : Migration Automatique emptyDir → PVC

**Phase 1 (Bootstrap)** : `configure_cilium.sh` crée le HelmChartConfig avec `dataStorage.enabled: false` (emptyDir). SPIRE fonctionne normalement mais perd ses données au restart (re-négociation ~30s).

**Phase 2.5 (Post-déploiement)** : `deploy-applicationsets.sh` exécute la migration automatique une fois le storage prêt :
1. Vérifie que `dataStorage.enabled=false` dans le HelmChartConfig K8s (skip si déjà migré)
2. Attend que le storage provider soit Ready (CephCluster + CephBlockPool pour Rook, ou StorageClass pour Longhorn)
3. Patche le HelmChartConfig K8s pour activer `dataStorage` avec le StorageClass et la taille configurés
4. Supprime `rke2-cilium-config.yaml` du disque via un Job K8s (évite la ré-application au reboot)
5. Le Helm controller détecte le changement et fait un `helm upgrade` automatique

### Configuration

```yaml
# config.yaml
features:
  cilium:
    mutualAuth:
      enabled: true
      port: 4250
      spire:
        dataStorage:
          enabled: true    # Migrer vers PVC après déploiement storage
          size: 1Gi        # Taille du PVC SPIRE Server
  storage:
    class: "ceph-block"    # StorageClass utilisé pour le PVC
```

### Comportement après migration

- **Reboot du cluster** : Pas de fichier `rke2-cilium-config.yaml` sur le disque → le HelmChartConfig dans etcd (avec `dataStorage: true`) est la source de vérité
- **Re-provisioning complet** : Le cycle complet Bootstrap → Migration se réexécute automatiquement
- **Migration déjà faite** : Détection au début, skip complet (idempotent)

### Vérification

```bash
# 1. Vérifier que le HelmChartConfig est patché
kubectl get helmchartconfig rke2-cilium -n kube-system -o jsonpath='{.spec.valuesContent}' | yq '.authentication.mutual.spire.install.server.dataStorage'

# 2. Vérifier que SPIRE utilise un PVC
kubectl get pvc -n cilium-spire

# 3. Vérifier que SPIRE est healthy
kubectl get pods -n cilium-spire

# 4. Vérifier que le fichier est supprimé du disque (SSH au master)
ls -la /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
# Attendu: No such file
```

### Impact

- **SPIRE restart** : ~30s de re-négociation des identités SPIFFE. La policy `mutual-auth-required` exclut `kube-system` et `cilium-spire`, donc SPIRE n'est pas bloqué.
- **Multi-master** : Le Job de suppression du fichier tourne sur un seul master. Les autres masters gardent le fichier, mais etcd est la source de vérité.

## Références

- [Cilium Documentation](https://docs.cilium.io/en/stable/)
- [Cilium Network Policies](https://docs.cilium.io/en/stable/security/policy/)
- [CiliumClusterwideNetworkPolicy](https://docs.cilium.io/en/stable/security/policy/language/#ciliumclusterwidenetworkpolicy)
- [Cilium Host Firewall](https://docs.cilium.io/en/stable/security/host-firewall/)
- [Cilium Observability Metrics](https://docs.cilium.io/en/stable/observability/metrics/)
- [Hubble Metrics](https://docs.cilium.io/en/stable/observability/metrics/#hubble-metrics)
- [Prometheus Operator ServiceMonitor](https://prometheus-operator.dev/docs/operator/design/#servicemonitor)
- [Prometheus Operator PodMonitor](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PodMonitor)
