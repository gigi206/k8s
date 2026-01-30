# LoxiLB

LoxiLB est un load balancer cloud-native open-source basé sur **eBPF/GoLang**, conçu pour les environnements Kubernetes on-premise, cloud public et hybrides.

## Caractéristiques

| Fonctionnalité | Support |
|----------------|---------|
| **Technologie** | eBPF (haute performance kernel-level) |
| **L4 Load Balancing** | ✅ TCP, UDP, SCTP (multi-homing), QUIC |
| **L7 Load Balancing** | ✅ HTTP/1.0, 1.1, 2.0 (via eBPF sockmap) |
| **Mode DSR** | ✅ Direct Server Return |
| **Support BGP** | ✅ Natif via GoBGP |
| **Mode L2** | ✅ ARP/NDP |
| **Proxy Protocol** | ✅ |
| **Dépendance CNI** | Aucune (fonctionne avec tout CNI) |
| **CNCF Status** | Sandbox project |

## Installation

Cette application utilise les **manifests officiels** de [kube-loxilb](https://github.com/loxilb-io/kube-loxilb) (pas de Helm chart).

### Structure des Sources

```
kustomize/
├── kube-loxilb/         # Controller (Deployment, RBAC)
│   ├── serviceaccount.yaml
│   ├── clusterrole.yaml
│   ├── clusterrolebinding.yaml
│   └── deployment.yaml
├── loxilb/              # Data plane L2 mode (DaemonSet)
│   ├── daemonset.yaml
│   └── service-headless.yaml
├── loxilb-bgp/          # Data plane BGP mode (DaemonSet)
│   ├── daemonset.yaml
│   └── service-headless.yaml
├── crds/                # CRDs pour BGP
│   └── bgppeerservice-crd.yaml
└── bgp/                 # BGPPeerService CR
    └── bgppeerservice.yaml
```

## Architecture

LoxiLB utilise une architecture à deux composants:

```
┌─────────────────────────────────────────────────────────────┐
│                    kube-system namespace                    │
│                                                             │
│  ┌─────────────────────────┐  ┌──────────────────────────┐ │
│  │    loxilb-lb DaemonSet  │  │   kube-loxilb Deployment │ │
│  │                         │  │                          │ │
│  │  • Data plane (eBPF)    │  │  • Control plane         │ │
│  │  • hostNetwork: true    │◄─┤  • Watches K8s Services  │ │
│  │  • Runs on ctrl-plane   │  │  • Configures loxilb API │ │
│  │  • Ports: 11111, 179    │  │  • Manages IP allocation │ │
│  └─────────────────────────┘  └──────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

### Provider Selection

Le provider LoadBalancer est configuré dans `config/config.yaml`:

```yaml
features:
  loadBalancer:
    enabled: true
    provider: "loxilb"  # metallb | cilium | loxilb
    mode: "l2"          # l2 | bgp
    pools:
      default:
        range: "192.168.121.220-192.168.121.250"
```

### Configuration Spécifique

Les fichiers `config/dev.yaml` et `config/prod.yaml` permettent de configurer:

| Paramètre | Description | Défaut |
|-----------|-------------|--------|
| `loxilb.loxilbImage` | Image loxilb | `ghcr.io/loxilb-io/loxilb` |
| `loxilb.loxilbTag` | Version de l'image loxilb | `v0.9.8` |
| `loxilb.kubeLoxilbImage` | Image kube-loxilb | `ghcr.io/loxilb-io/kube-loxilb` |
| `loxilb.kubeLoxilbTag` | Version de l'image kube-loxilb | `v0.9.8` |
| `loxilb.setLBMode` | Mode LB (0=DNAT, 1=onearm, 2=fullNAT) | `0` |

### Modes de Load Balancing

| Mode | Valeur | Description |
|------|--------|-------------|
| **DNAT** | `0` | Destination NAT standard (défaut) |
| **One-ARM** | `1` | Mode interface unique |
| **FullNAT** | `2` | Full NAT avec réécriture source |

### Mode BGP

Pour activer le mode BGP au lieu de L2:

```yaml
features:
  loadBalancer:
    mode: "bgp"
    bgp:
      localASN: 64512
      peers:
        - address: "192.168.121.1"
          asn: 64512
```

En mode BGP, l'ApplicationSet déploie automatiquement:
- Les CRDs BGP (`bgppeerservices.bgppeer.loxilb.io`)
- Le DaemonSet loxilb avec `--bgp` flag
- Le CR `BGPPeerService` configuré avec les peers

## LoadBalancerClass

LoxiLB utilise sa propre LoadBalancerClass. Pour qu'un Service utilise LoxiLB:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  loadBalancerClass: loxilb.io/loxilb  # Requis pour LoxiLB
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

**Note**: Sans `loadBalancerClass`, les Services ne seront pas pris en charge par LoxiLB.

## Annotations de Service

LoxiLB supporte plusieurs annotations pour personnaliser le comportement:

| Annotation | Description | Valeurs |
|------------|-------------|---------|
| `loxilb.io/lbmode` | Mode LB par service | `default`, `onearm`, `fullnat`, `dsr` |
| `loxilb.io/liveness` | Health probing | `yes`, `no` |
| `loxilb.io/epselect` | Algorithme de sélection | `roundrobin`, `hash`, `persist`, `leastconn` |
| `loxilb.io/probetype` | Type de health check | `tcp`, `udp`, `http`, `https` |
| `loxilb.io/probeport` | Port du health check | Port number |
| `loxilb.io/staticIP` | IP externe fixe | IP address |

### Exemple avec DSR

```yaml
apiVersion: v1
kind: Service
metadata:
  name: high-perf-service
  annotations:
    loxilb.io/lbmode: "dsr"
    loxilb.io/liveness: "yes"
    loxilb.io/probetype: "tcp"
    loxilb.io/epselect: "roundrobin"
spec:
  type: LoadBalancer
  loadBalancerClass: loxilb.io/loxilb
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

## Comparaison avec MetalLB et Cilium LB-IPAM

| Aspect | LoxiLB | MetalLB | Cilium LB-IPAM |
|--------|--------|---------|----------------|
| **Performance** | Haute (eBPF) | Modérée (iptables) | Haute (eBPF) |
| **DSR Support** | ✅ | ❌ | ✅ |
| **L7 Natif** | ✅ | ❌ | Via Envoy |
| **CNI Required** | Non | Non | Cilium |
| **VM Compatible** | ✅ | ✅ | ✅ (config requise) |
| **Maturité** | CNCF Sandbox | Mature | Mature |

### Quand choisir LoxiLB?

- Besoin de **DSR** (Direct Server Return) pour haute performance
- Besoin de **L7 load balancing** sans composant externe
- Besoin de **SCTP multi-homing** (5G/Telco)
- Utilisation d'un CNI autre que Cilium mais besoin de performance eBPF

## Limitation avec Cilium CNI

> **⚠️ Important** : LoxiLB et Cilium utilisent tous deux des hooks eBPF/XDP et **ne peuvent pas coexister** sur les mêmes interfaces réseau sans configuration spéciale.

### Problème

Quand LoxiLB est déployé avec Cilium comme CNI :
- Cilium attache ses programmes XDP/TC sur les interfaces réseau (eth0)
- LoxiLB tente d'attacher ses propres programmes eBPF sur les mêmes interfaces
- Les deux programmes entrent en conflit, causant des échecs de forwarding
- Les services LoadBalancer obtiennent des IPs mais le trafic n'est pas routé

**Symptômes** :
```bash
# Le ping vers l'IP LoadBalancer fonctionne (ARP OK)
ping 192.168.121.210  # ✅ OK

# Mais les connexions TCP échouent
curl https://192.168.121.210  # ❌ Connection refused

# Les compteurs loxilb restent à 0
kubectl exec -n kube-system loxilb-lb-xxx -- loxicmd get lb -o wide
# COUNTERS: 0:0
```

### Solution : Multus CNI

Selon la [documentation officielle](https://docs.loxilb.io/latest/cilium-incluster/), pour faire coexister LoxiLB et Cilium :

1. **Installer Multus CNI** pour créer des interfaces réseau secondaires
2. **Configurer Cilium** avec `cni-exclusive: false`
3. **Créer une NetworkAttachmentDefinition** macvlan pour LoxiLB
4. **Annoter les pods LoxiLB** avec `k8s.v1.cni.cncf.io/networks`

Cette configuration isole le trafic LoxiLB dans des interfaces distinctes de celles gérées par Cilium.

### Alternatives recommandées

Si vous utilisez Cilium comme CNI, considérez ces alternatives :

| Alternative | Avantages | Inconvénients |
|-------------|-----------|---------------|
| **MetalLB** | Simple, mature, compatible Cilium | Pas de DSR, performance moindre |
| **Cilium LB-IPAM** | Natif Cilium, haute performance | Interface L2 doit être dans devices Cilium |
| **LoxiLB + Multus** | Toutes les fonctionnalités LoxiLB | Configuration complexe |

### Vérification de la compatibilité

```bash
# Vérifier si Cilium XDP est attaché
kubectl exec -n kube-system ds/cilium -- ip link show eth0 | grep xdp
# prog/xdp id XXXX = Cilium XDP actif, conflit probable

# Vérifier les erreurs loxilb
kubectl logs -n kube-system -l app=loxilb-app | grep -i "failed\|error"
```

## Troubleshooting

### Vérifier le déploiement

```bash
# Vérifier les pods
kubectl get pods -n kube-system -l app=loxilb-app
kubectl get pods -n kube-system -l app=kube-loxilb-app

# Logs kube-loxilb (control plane)
kubectl logs -n kube-system -l app=kube-loxilb-app -f

# Logs loxilb-lb (data plane)
kubectl logs -n kube-system -l app=loxilb-app -f
```

### Service sans IP externe

```bash
# Vérifier le LoadBalancerClass
kubectl get svc <service-name> -o yaml | grep loadBalancerClass

# Le service doit avoir:
#   loadBalancerClass: loxilb.io/loxilb

# Vérifier les événements
kubectl describe svc <service-name>
```

### Erreur RBAC

Si kube-loxilb affiche des erreurs de permission:
```
namespaces is forbidden: User "system:serviceaccount:kube-system:kube-loxilb" cannot list resource "namespaces"
```

Vérifiez que le ClusterRole est à jour avec les permissions `namespaces`, `secrets`, et `gateway.networking.k8s.io`.

### API LoxiLB

```bash
# Accéder à l'API loxilb (depuis un nœud control-plane)
curl http://localhost:11111/netlox/v1/config/loadbalancer/all
```

## Références

- [Documentation LoxiLB](https://docs.loxilb.io/latest/)
- [GitHub kube-loxilb](https://github.com/loxilb-io/kube-loxilb)
- [Manifests officiels](https://github.com/loxilb-io/kube-loxilb/tree/main/manifest/in-cluster)
- [GitHub loxilb](https://github.com/loxilb-io/loxilb)
- [LoxiLB + Cilium Integration](https://docs.loxilb.io/latest/cilium-incluster/)
