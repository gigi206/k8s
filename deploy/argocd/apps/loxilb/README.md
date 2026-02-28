# LoxiLB

LoxiLB est un load balancer cloud-native open-source basé sur **eBPF/GoLang**, conçu pour les environnements Kubernetes on-premise, cloud public et hybrides.

## Caractéristiques

| Fonctionnalité        | Support                                  |
| --------------------- | ---------------------------------------- |
| **Technologie**       | eBPF (haute performance kernel-level)    |
| **L4 Load Balancing** | ✅ TCP, UDP, SCTP (multi-homing), QUIC   |
| **L7 Load Balancing** | ✅ HTTP/1.0, 1.1, 2.0 (via eBPF sockmap) |
| **Mode DSR**          | ✅ Direct Server Return                  |
| **Support BGP**       | ✅ Natif via GoBGP                       |
| **Mode L2**           | ✅ ARP/NDP                               |
| **Proxy Protocol**    | ✅                                       |
| **Dépendance CNI**    | Aucune (fonctionne avec tout CNI)        |
| **CNCF Status**       | Sandbox project                          |

## Installation

Cette application utilise les **manifests officiels** de [kube-loxilb](https://github.com/loxilb-io/kube-loxilb) (pas de Helm chart).

### Structure des Sources

```
kustomize/
├── kube-loxilb/              # Controller in-cluster (Deployment, RBAC)
│   ├── serviceaccount.yaml
│   ├── clusterrole.yaml
│   ├── clusterrolebinding.yaml
│   └── deployment.yaml
├── kube-loxilb-external/     # Controller external mode k3d (Deployment, RBAC réutilisé)
│   ├── kustomization.yaml
│   └── deployment.yaml
├── loxilb/                   # Data plane L2 mode (DaemonSet)
│   ├── daemonset.yaml
│   └── service-headless.yaml
├── loxilb-bgp/               # Data plane BGP mode (DaemonSet)
│   ├── daemonset.yaml
│   └── service-headless.yaml
├── crds/                     # CRDs pour BGP
│   └── bgppeerservice-crd.yaml
└── bgp/                      # BGPPeerService CR
    └── bgppeerservice.yaml

scripts/
└── start-loxilb-external.sh  # Lance le container LoxiLB externe (mode k3d)
```

## Architecture

LoxiLB utilise une architecture à deux composants:

```
┌─────────────────────────────────────────────────────────────┐
│                    kube-system namespace                    │
│                                                             │
│  ┌─────────────────────────┐  ┌──────────────────────────┐  │
│  │    loxilb-lb DaemonSet  │  │   kube-loxilb Deployment │  │
│  │                         │  │                          │  │
│  │  • Data plane (eBPF)    │  │  • Control plane         │  │
│  │  • hostNetwork: true    │◄─┤  • Watches K8s Services  │  │
│  │  • Runs on ctrl-plane   │  │  • Configures loxilb API │  │
│  │  • Ports: 11111, 179    │  │  • Manages IP allocation │  │
│  └─────────────────────────┘  └──────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Mode External avec k3d

LoxiLB supporte un **mode external** où le container LoxiLB tourne en dehors du cluster k3d, directement sur l'hôte Docker. Ce mode est concu pour les environnements k3d où le data plane eBPF ne peut pas fonctionner dans les containers k3d (noyau partagé avec l'hôte, eBPF non disponible dans les namespaces réseau Docker).

### Pourquoi le mode External pour k3d ?

k3d fait tourner les noeuds Kubernetes dans des containers Docker. Dans ce contexte :

- Les nodes k3d partagent le noyau Linux de l'hôte mais ont leurs propres namespaces réseau Docker
- LoxiLB en mode in-cluster devrait s'attacher aux interfaces réseau Docker internes des nodes, ce qui n'est pas possible sans `--net=host`
- Les VIPs LoadBalancer doivent être accessibles depuis l'hôte Docker (pour les tests locaux)
- Le réseau k3d utilise un bridge Docker (`172.18.0.0/16` par défaut pour le réseau `k3d-<cluster>`)

**Solution** : LoxiLB tourne sur l'hôte avec `--net=host`, ce qui lui donne accès aux interfaces physiques de l'hôte. kube-loxilb (dans le cluster k3d) se connecte à l'API LoxiLB via l'IP du bridge Docker de l'hôte.

### Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  Hote Docker (Linux)                                               │
│                                                                    │
│  ┌─────────────────────────────────────────────┐                   │
│  │  Container LoxiLB (--net=host, --privileged)│                   │
│  │                                             │                   │
│  │  • Data plane eBPF sur interfaces hote      │                   │
│  │  • API REST: 0.0.0.0:11111                  │                   │
│  │  • VIPs allouees sur l'hote                 │                   │
│  └─────────────────────────────────────────────┘                   │
│                                                                    │
│  docker0 / k3d-<cluster> bridge: 172.18.0.0/16                     │
│                          │                                         │
│  ┌───────────────────────┼──────────────────────────────────────┐  │
│  │  Cluster k3d          │                                      │  │
│  │                       │                                      │  │
│  │  ┌────────────────────▼────────────────────────────────────┐ │  │
│  │  │  kube-loxilb Deployment (kube-system)                   │ │  │
│  │  │                                                         │ │  │
│  │  │  • Control plane                                        │ │  │
│  │  │  • --loxiURL=http://172.18.0.1:11111                    │ │  │
│  │  │  • Watches K8s Services type LoadBalancer               │ │  │
│  │  │  • Configure LoxiLB via API REST                        │ │  │
│  │  └─────────────────────────────────────────────────────────┘ │  │
│  │                                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**Flux de trafic (mode onearm, setLBMode=1) :**

```
Client → VIP sur l'hote → LoxiLB (eBPF DNAT) → Pod IP dans k3d → reponse directe au client
```

### Procedure d'installation

**Important** : Le container LoxiLB doit etre lance **avant** de creer le cluster k3d et de deployer l'ApplicationSet ArgoCD.

#### Etape 1 : Lancer LoxiLB sur l'hote

```bash
# Depuis la racine du repo
./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh

# Verifier le statut
./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh --status

# Variables d'environnement optionnelles
LOXILB_IMAGE=ghcr.io/loxilb-io/loxilb:v0.9.8 \
  ./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh
```

Le script :

- Lance un container Docker avec `--net=host --privileged`
- Attend que l'API LoxiLB soit disponible sur `http://127.0.0.1:11111`
- Affiche l'URL a configurer dans `loxilb.loxiURL`
- Est **idempotent** : si le container tourne deja, il affiche simplement le statut

#### Etape 2 : Identifier l'IP du bridge k3d

```bash
# Trouver l'IP de l'hote sur le bridge Docker k3d
docker network inspect k3d-<cluster-name> --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
# Exemple: 172.18.0.1

# Ou utiliser l'IP principale de l'hote
hostname -I | awk '{print $1}'
```

#### Etape 3 : Configurer dev.yaml

```yaml
# deploy/argocd/apps/loxilb/config/dev.yaml
loxilb:
  mode: "external" # Flag explicite requis (pas de deduction automatique)
  loxiURL: "http://172.18.0.1:11111" # IP hote sur bridge k3d
  setLBMode: 1 # onearm (requis pour external mode)

features:
  loadBalancer:
    provider: "loxilb"
    pools:
      default:
        range: "172.18.0.200-172.18.0.220" # VIPs dans le sous-reseau k3d
```

#### Etape 4 : Creer le cluster k3d et deployer

```bash
# Creer le cluster k3d (apres que LoxiLB tourne)
k3d cluster create my-cluster ...

# Deployer les ApplicationSets
make argocd-install-dev
```

### Configuration ApplicationSet

Le mode est contrôlé par le flag explicite `loxilb.mode` dans la config de l'environnement. L'ApplicationSet utilise `{{- if eq .loxilb.mode "external" }}` pour sélectionner `kube-loxilb-external` au lieu de `kube-loxilb` + DaemonSet loxilb. Il n'y a pas de déduction automatique depuis `cluster.distribution`.

```yaml
# deploy/argocd/apps/loxilb/config/dev.yaml (k3d)
loxilb:
  mode: "external"           # Flag explicite requis
  loxiURL: "http://172.18.0.1:11111"
  setLBMode: 1

# deploy/argocd/apps/loxilb/config/prod.yaml (RKE2)
loxilb:
  mode: "internal"           # Flag explicite requis
  setLBMode: 0
```

```yaml
# Dans config/config.yaml
features:
  loadBalancer:
    enabled: true
    provider: "loxilb"
    pools:
      default:
        range: "172.18.0.200-172.18.0.220"
```

### Gestion du container LoxiLB externe

```bash
# Demarrer
./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh

# Verifier le statut et tester l'API
./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh --status

# Arreter et supprimer
./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh --stop

# Specifier une image differente
LOXILB_IMAGE=ghcr.io/loxilb-io/loxilb:v0.9.9 \
  ./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh

# Specifier un nom de container different (multi-cluster)
LOXILB_NAME=loxilb-cluster2 \
  ./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh
```

## Mode External via VM Vagrant (RKE2)

En environnement Vagrant avec RKE2, le mode external déploie LoxiLB sur une **VM dédiée** (`k8s-<cluster>-loxilb`) distincte des nodes master/worker. Cette séparation évite les conflits eBPF entre loxilb et Cilium (qui tournent tous deux avec des hooks TC/XDP).

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Hote Vagrant (Linux)   192.168.121.0/24 (libvirt bridge virbr1)        │
│                                                                         │
│  ┌──────────────────────────────────────────┐                           │
│  │  VM k8s-dev-loxilb1                       │                           │
│  │  eth0: 192.168.121.5/32  (Vagrant mgmt)  │                           │
│  │  eth1: 192.168.121.40/24 (LoxiLB WAN)    │                           │
│  │                                          │                           │
│  │  ┌─────────────────────────────────────┐ │                           │
│  │  │ Container loxilb-external           │ │                           │
│  │  │ --net=host --privileged             │ │                           │
│  │  │ --whitelist=eth1                    │ │                           │
│  │  │ --bgp (si BGP active)               │ │                           │
│  │  │ API REST: 0.0.0.0:11111             │ │                           │
│  │  │ GoBGP  : 0.0.0.0:179                │ │                           │
│  │  └─────────────────────────────────────┘ │                           │
│  └──────────────────────────────────────────┘                           │
│              │ BGP session (ASN 65002 <-> 64512)                        │
│              │ VIP GARPs via eth1                                       │
│  ┌───────────┼─────────────────────────────────────────────────────┐    │
│  │  Cluster RKE2                                                   │    │
│  │                                                                 │    │
│  │  ┌──────────────────────────────────────────────────────────┐   │    │
│  │  │  kube-loxilb Deployment (kube-system)                    │   │    │
│  │  │  --loxiURL=http://192.168.121.40:11111                   │   │    │
│  │  │  --setBGP=65002 --extBGPPeers=192.168.121.50:64512       │   │    │
│  │  └──────────────────────────────────────────────────────────┘   │    │
│  │                                                                 │    │
│  │  ┌──────────────────────────────────────────────────────────┐   │    │
│  │  │  Cilium CNI (ASN 64512)                                  │   │    │
│  │  │  bgpControlPlane.enabled: true                           │   │    │
│  │  │  Advertise PodCIDR via BGP vers loxilb                   │   │    │
│  │  └──────────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

**Flux de trafic :**

```
Client (hote) → VIP 192.168.121.210 (eth1 loxilb VM) → loxilb eBPF DNAT
              → Pod 10.42.x.x (route BGP apprise) → reponse directe
```

### Provisioning automatique

Le Vagrantfile crée la VM `k8s-dev-loxilb1` et appelle `provision-loxilb-external.sh` automatiquement quand `LB_PROVIDER=loxilb` et `loxilb.mode: "external"` dans `config/dev.yaml`.

Le script installe Docker, applique les fixes réseau (voir ci-dessous) et démarre le container loxilb.

### Configuration requise

```yaml
# deploy/argocd/apps/loxilb/config/dev.yaml
loxilb:
  mode: "external"
  loxiURL: "http://192.168.121.40:11111" # IP eth1 de la VM loxilb
  setLBMode: 0 # DNAT (0) - BGP gere le routing retour
  bgp:
    enabled: true
    localASN: 65002 # ASN loxilb externe
    extBGPPeers: "192.168.121.50:64512" # master_ip:cilium_asn
```

---

## Probleme : ARP/GARP avec VM dual-interface sur meme sous-reseau

> **Probleme critique** : loxilb envoie les GARP (Gratuitous ARP) avec la MAC de **eth0** (interface Vagrant management) au lieu de **eth1** (interface de travail), causant l'echec du trafic vers les VIPs.

### Contexte

La VM loxilb a deux interfaces sur le **meme sous-reseau** `192.168.121.0/24` :

- `eth0` : interface Vagrant management, IP DHCP (`192.168.121.5`), **non utilisee par loxilb**
- `eth1` : interface de travail loxilb, IP statique (`192.168.121.40`), **eBPF attach**

### Cause racine : `IfaSelectAny()` dans loxilb

LoxiLB choisit l'interface GARP via la fonction `IfaSelectAny()` dans `pkg/loxinet/layer3.go` :

1. Cherche une route dans son trie interne qui contient l'IP VIP
2. Retourne l'interface associee a cette route

Au demarrage, `NlpGet()` traite **eth0 avant eth1** (ordre alphabetique/index). eth0's route `/24` (`192.168.121.0/24`) est inseree en premier dans le trie. Quand eth1 tente d'ajouter la meme route `/24`, elle echoue avec `"subnet-route add error"`. Resultat : `IfaSelectAny()` trouve eth0 dans le trie pour toute VIP dans `192.168.121.0/24` → GARP envoye avec la MAC de eth0.

**Symptomes** :

```bash
# VIP .201 (DNS) → MAC eth1 ✅  (route apprise differemment)
ip neigh show 192.168.121.201
# 192.168.121.201 dev virbr1 lladdr 52:54:00:6d:1c:d1 REACHABLE

# VIP .210 (HTTPS) → MAC eth0 ❌
ip neigh show 192.168.121.210
# 192.168.121.210 dev virbr1 lladdr 52:54:00:bc:72:d2 STALE

# Trafic arrive sur eth0 → eBPF loxilb est sur eth1 → pas d'intercept → RST
curl https://argocd.k8s.lan  # Connection refused / timeout
```

### Fixes implementes

**Fix 1 — eth0 en /32** (dans `provision-loxilb-external.sh`, service systemd `loxilb-eth0-fix.service`) :

Changer eth0 de `/24` en `/32` supprime la route `192.168.121.0/24` du trie loxilb pour eth0. Seule eth1 a la route `/24` → `IfaSelectAny()` retourne eth1 → GARP avec MAC eth1.

```bash
ip addr del 192.168.121.5/24 dev eth0
ip addr add 192.168.121.5/32 dev eth0
ip route add 192.168.121.1/32 dev eth0 scope link
ip route add default via 192.168.121.1 dev eth0
```

**Fix 2 — `arp_ignore=1` sur eth0** (dans `/etc/sysctl.d/99-loxilb-arp.conf`) :

Empeche le noyau de repondre aux requetes ARP broadcast pour les VIPs via eth0 (les VIPs sont sur `lo`).

```bash
sysctl -w net.ipv4.conf.eth0.arp_ignore=1
```

**Fix 3 — `--whitelist=eth1`** (argument Docker) :

Restreint le chargement des hooks eBPF TC et le traitement netlink a eth1 uniquement. Complementaire aux fixes 1 et 2.

**Fix 4 — Neighbors permanents sur eth1** (dans `loxilb-eth0-fix.sh`, section Fix 3 du script) :

loxilb (`--whitelist=eth1`) ne monitore que les neighbors eth1 pour sa **neighbor map interne** (peuplee via netlink depuis le cache ARP kernel — PAS via `bpf_fib_lookup`). Sur le chemin reverse NAT (SYN-ACK backend → client), l'eBPF cherche la MAC du next-hop dans cette map. Si le client est derriere la gateway (.1) ou le VRRP VIP (.44), et que ces MACs ne sont pas dans la neighbor table eth1, le lookup echoue → `TC_ACT_OK` → kernel envoie RST.

Le script ajoute des entrees ARP **PERMANENT** sur eth1 pour :
- La gateway (`.1`) — pour les clients derriere la route par defaut
- Le VRRP VIP (`.44`) — pour le trafic route via le FRR anycast VIP

La resolution MAC utilise `arping` (requete ARP active) avec un retry loop (10 tentatives, 2s entre chaque). `arping` est installe automatiquement (`iputils-arping`) pendant le provisionnement. L'adresse VRRP VIP est lue depuis `config.yaml` et ecrite dans `/etc/loxilb/extra-neighbors.conf`.

```bash
# Verification des neighbors permanents
vagrant ssh k8s-dev-loxilb1 -- ip neigh show dev eth1 | grep PERMANENT
# 192.168.121.1  lladdr 52:54:00:fc:22:22 PERMANENT
# 192.168.121.44 lladdr 52:54:00:xx:xx:xx PERMANENT

# Logs du service systemd au boot
vagrant ssh k8s-dev-loxilb1 -- sudo journalctl -u loxilb-eth0-fix.service | grep OK
# [OK] eth0 set to /32: 192.168.121.x/32
# [OK] 192.168.121.1 (52:54:00:FC:22:22) added to eth1 neighbor table
# [OK] 192.168.121.44 (52:54:00:XX:XX:XX) added to eth1 neighbor table
```

**Persistance** : Les fixes 1, 2 et 4 sont automatiquement appliques au boot via un service systemd `loxilb-eth0-fix.service` (avec `Before=docker.service`) et `/etc/sysctl.d/`.

### Verification post-fix

```bash
# VIP .210 doit pointer vers eth1 MAC (52:54:00:6d:1c:d1 = eth1)
ip neigh show 192.168.121.210
# 192.168.121.210 dev virbr1 lladdr 52:54:00:6d:1c:d1 REACHABLE  ✅

# Les deux VIPs doivent avoir le meme MAC (eth1)
# Compteurs LoxiLB doivent augmenter
kubectl exec -n kube-system deploy/kube-loxilb -- loxicmd get lb -o wide | grep -E "201|210"

# Test HTTPS
curl -sk https://argocd.k8s.lan | head -1  # Doit retourner HTML ✅
```

---

## BGP peering Cilium <-> LoxiLB externe

Deux modes BGP sont disponibles selon `features.loadBalancer.mode` dans `config/config.yaml` :

- **Mode `l2`** : le BGP sert **uniquement** au routage PodCIDR (loxilb apprend `10.42.0.0/24` depuis Cilium). Les VIPs sont annoncees via GARP/ARP, pas via BGP. Peering direct loxilb ↔ Cilium.
- **Mode `bgp`** : les VIPs sont annoncees via BGP /32. Une VM FRR intermediaire est obligatoire. Peering loxilb ↔ FRR ↔ Cilium.

### Mode L2 — BGP PodCIDR direct (loadBalancer.mode: l2)

```
    ┌──────────────────────────────────────────────────────────────────┐
    │  HÔTE  (libvirt virbr0 — 192.168.121.0/24)                       │
    │  $ curl https://argocd.k8s.lan  →  DNS: 192.168.121.210          │
    └──────────────────────────────┬───────────────────────────────────┘
                                   │
               GARP loxilb → MAC eth1 pour .210/.201
               trafic IP → loxilb direct → DNAT → pod
                                   │
                                   ▼
┌──────────────────────┐                          ┌──────────────────────┐
│   k8s-dev-loxilb1     │    eBGP TCP/179          │    k8s-dev-m1        │
│   192.168.121.40     │◄────────────────────────►│    192.168.121.50    │
│                      │  ASN 65002 ↔ ASN 64512   │                      │
│   loxilb             │                          │   Cilium (ASN 64512) │
│   GoBGP (ASN 65002)  │  ← PodCIDR 10.42/24      │   bgpControlPlane    │
│                      │ (pas d'annonce VIPs BGP) │                      │
│   LB Rules (onearm): │                          │   kube-loxilb:       │
│   .210:80  → :10080  │                          │   --loxiURL=.40:11111│
│   .210:443 → :10443  │                          │   --setBGP=65002     │
│   .201:53  → :53     │                          │   --extBGPPeers=     │
│                      │                          │     .50:64512        │
│   GARP → VIPs /32    │                          │                      │
│   DNAT → 10.42.0.x   │                          │   Pods:              │
└──────────┬───────────┘                          │   .206 envoy-gw      │
           │                                      │   .210 coredns       │
           │◄──────── REST API HTTP :11111 ────── │                      │
           │          (programme les règles LB)   └──────────────────────┘
```

### Mode BGP — FRR comme intermédiaire (loadBalancer.mode: bgp)

```
    ┌─────────────────────────────────────────────────────────────────────────────┐
    │  HÔTE  (libvirt virbr0 — 192.168.121.0/24)                                  │
    │  $ curl https://argocd.k8s.lan  →  DNS: 192.168.121.210                     │
    └──────────────────────────────────────┬──────────────────────────────────────┘
                                           │
                  ARP .210/.201 ?          │        FRR répond (proxy-ARP eth1)
                  trafic IP vers .210 ─────▼──► FRR route vers .40 ──► DNAT pod
                                           │
                                           ▼
┌──────────────────────┐  eBGP TCP/179  ┌──────────────────────┐  eBGP TCP/179  ┌──────────────────────┐
│   k8s-dev-loxilb1     │                │    k8s-dev-frr1       │                │    k8s-dev-m1        │
│   192.168.121.40     │◄──────────────►│    192.168.121.45    │◄──────────────►│    192.168.121.50    │
│                      │  ASN 65002     │                      │  ASN 65000     │                      │
│   loxilb             │      ↕         │   FRR (ASN 65000)    │      ↕         │   Cilium (ASN 64512) │
│   GoBGP (ASN 65002)  │  ASN 65000     │   proxy_arp eth1=1   │  ASN 64512     │   bgpControlPlane    │
│                      │                │   ip_forward=1       │                │                      │
│                      │ → VIPs /32     │                      │ → VIPs /32     │                      │
│                      │ ← PodCIDR /24  │   BGP RIB:           │ ← PodCIDR /24  │                      │
│                      │                │   .210/32  via .40   │                │                      │
│   LB Rules (onearm): │                │   .201/32  via .40   │                │   kube-loxilb:       │
│   .210:80  → :10080  │                │   10.42/24 via .50   │                │   --loxiURL=.40:11111│
│   .210:443 → :10443  │                │                      │                │   --setBGP=65002     │
│   .201:53  → :53     │                │                      │                │   --extBGPPeers=.45  │
│                      │                │                      │                │                      │
│   DNAT → 10.42.0.x   │                │                      │                │   Pods:              │
└──────────┬───────────┘                └──────────────────────┘                │   .206 envoy-gw      │
           │                                                                    │   .210 coredns       │
           │◄──────────────────────── REST API HTTP :11111 ──────────────────── │                      │
           │                      (programme les règles LB)                     └──────────────────────┘
```

### Comparaison L2 vs BGP pur

| Aspect              | Mode `l2`                      | Mode `bgp`                          |
| ------------------- | ------------------------------ | ----------------------------------- |
| **Annonce VIPs**    | GARP/ARP (L2)                  | BGP /32 routes (L3)                 |
| **VM FRR requise**  | Non                            | Oui (`k8s-dev-frr1`, ASN 65000)      |
| **Peering loxilb**  | Direct vers Cilium (.50:64512) | Vers FRR uniquement (.45:65000)     |
| **Peering Cilium**  | Vers loxilb (.40:65002)        | Vers FRR (.45:65000)                |
| **proxy-ARP**       | Non (GARP suffit)              | Oui — eth1 FRR repond pour les VIPs |
| **Routage PodCIDR** | Appris via BGP depuis Cilium   | Appris via BGP depuis Cilium (idem) |
| **`--extBGPPeers`** | `192.168.121.50:64512`         | `192.168.121.45:65000`              |

### Configuration

```yaml
# deploy/argocd/apps/loxilb/config/dev.yaml
loxilb:
  bgp:
    enabled: true
    localASN: 65002
    extBGPPeers: "192.168.121.50:64512"
```

ArgoCD deploie automatiquement (via ApplicationSet) :

- `CiliumBGPPeeringPolicy` — Cilium ecoute BGP et advertise les PodCIDRs
- `loxilb-bgp-host-ingress` — autorise le port 179 TCP depuis la VM loxilb
- `loxilb-allow-external-ingress` — autorise l'ingress pods depuis loxilb (DNAT)
- kube-loxilb avec `--setBGP=65002 --extBGPPeers=...` — programme loxilb via API

### Verification BGP

#### Mode L2 — peering direct loxilb ↔ Cilium

```bash
# Session BGP etablie (peer = Cilium master .50)
vagrant ssh k8s-dev-loxilb1 -- docker exec loxilb-external gobgp neighbor
# Peer           AS      Up/Down  State       |#Received  Accepted
# 192.168.121.50 64512  00:27:34 Established |        1         1

# Routes PodCIDR apprises par loxilb
vagrant ssh k8s-dev-loxilb1 -- docker exec loxilb-external gobgp global rib
# Network         Next Hop        AS_PATH  Age        Attrs
# 10.42.0.0/24   192.168.121.50  64512   00:27:34   [{Origin: i}]

# CiliumBGPPeeringPolicy
kubectl get ciliumbgppeeringpolicy loxilb-external-bgp -o yaml

# Test end-to-end (DNS via VIP)
dig @192.168.121.201 google.com
```

#### Mode BGP — peering via FRR intermédiaire

```bash
# 1. Verifier la session BGP loxilb ↔ FRR (peer = FRR .45)
vagrant ssh k8s-dev-loxilb1 -- docker exec loxilb-external gobgp neighbor
# Peer           AS      Up/Down  State       |#Received  Accepted
# 192.168.121.45 65000  00:15:12 Established |        1         1

# Routes VIPs annoncees par loxilb vers FRR
vagrant ssh k8s-dev-loxilb1 -- docker exec loxilb-external gobgp global rib
# Network            Next Hop  AS_PATH  Age        Attrs
# 192.168.121.210/32 0.0.0.0  65002   00:15:12   [{Origin: i}]
# 192.168.121.201/32 0.0.0.0  65002   00:15:12   [{Origin: i}]

# 2. Verifier la table BGP FRR (sessions des deux cotes)
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show bgp summary"
# Neighbor        V  AS      MsgRcvd  MsgSent  TblVer  InQ  OutQ  Up/Down  State/PfxRcd
# 192.168.121.40  4  65002   ...      ...      ...     0    0     ...      2
# 192.168.121.50  4  64512   ...      ...      ...     0    0     ...      1

# Routes dans la RIB FRR
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show ip route bgp"
# B>* 10.42.0.0/24       [20/0] via 192.168.121.50, eth1
# B>* 192.168.121.210/32 [20/0] via 192.168.121.40, eth1
# B>* 192.168.121.201/32 [20/0] via 192.168.121.40, eth1

# 3. Verifier la session BGP Cilium ↔ FRR (peer = FRR .45)
kubectl get ciliumbgppeeringpolicy loxilb-external-bgp -o yaml

# 4. Verifier le proxy-ARP sur FRR (eth1 doit repondre pour les VIPs)
vagrant ssh k8s-dev-frr1 -- cat /proc/sys/net/ipv4/conf/eth1/proxy_arp
# Attendu: 1

# Test end-to-end
dig @192.168.121.201 google.com
curl -sk https://argocd.k8s.lan | head -1
```

---

## Architecture production : BGP pur avec routeurs physiques

En environnement client avec des routeurs BGP physiques (Cisco, Juniper, Arista), le mode L2/GARP est remplace par du **BGP pur actif/actif**. C'est l'architecture de reference pour la haute disponibilite et la scalabilite.

```
                        ┌──────────────────────────────────────────┐
                        │   Routeurs physiques   ASN 65000         │
                        │   (Cisco / Juniper / Arista)             │
                        │                                          │
                        │   VIP 10.0.1.0/24 → ECMP                 │
                        │     next-hop 10.0.0.1  (loxilb-1)        │
                        │     next-hop 10.0.0.2  (loxilb-2)        │
                        │                                          │
                        │   Hash par flow (src+dst IP+port)        │
                        │   → meme connexion = meme loxilb         │
                        └──────┬──────────────────────┬────────────┘
                   eBGP        │                      │       eBGP
                   ASN 65002   │                      │   ASN 65002
                        ┌──────▼──────┐        ┌──────▼──────┐
                        │  loxilb-1   │        │  loxilb-2   │
                        │  10.0.0.1   │        │  10.0.0.2   │
                        │  GoBGP      │        │  GoBGP      │
                        │             │        │             │
                        │ Advertise:  │        │ Advertise:  │
                        │  VIP/32     │        │  VIP/32     │
                        └──────┬──────┘        └──────┬──────┘
                               │  eBGP   ASN 64512    │
                               └──────────┬───────────┘
                                          │
                        ┌─────────────────▼──────────────────────┐
                        │   Cluster Kubernetes (Cilium)          │
                        │   ASN 64512                            │
                        │                                        │
                        │   Advertise vers loxilb-1 et loxilb-2: │
                        │     PodCIDR 10.42.0.0/16               │
                        │                                        │
                        │   ┌─────────┐  ┌─────────┐             │
                        │   │ node-1  │  │ node-2  │  ...        │
                        │   │ pods    │  │ pods    │             │
                        │   └─────────┘  └─────────┘             │
                        └────────────────────────────────────────┘
```

### Flux de trafic (actif/actif ECMP)

```
Client → VIP 10.0.1.210
  → routeur : hash(src,dst,sport,dport) → loxilb-1
  → loxilb-1 eBPF DNAT → pod 10.42.x.x (route BGP apprise)
  → reponse directe pod → client

Autre connexion → meme VIP
  → routeur : hash different → loxilb-2
  → loxilb-2 eBPF DNAT → pod 10.42.y.y
```

### Comparaison avec le setup Vagrant

| Aspect               | Vagrant (lab)        | Production (routeurs BGP)       |
| -------------------- | -------------------- | ------------------------------- |
| **VIP announcement** | GARP (L2)            | BGP (L3)                        |
| **Nombre loxilb**    | 1 VM                 | 2+ (actif/actif)                |
| **Failover**         | Manuel / redemarrage | Automatique via BFD (< 1s)      |
| **ECMP**             | Non                  | Oui (routeur hash par flow)     |
| **ARP/GARP**         | Requis               | Non (routage L3 pur)            |
| **Scalabilite**      | Limitee              | Ajouter un peer BGP = scale-out |
| **Routeur upstream** | virbr1 (pas BGP)     | Cisco/Juniper/Arista/FRR        |

### Failover BGP avec BFD

En production, **BFD** (Bidirectional Forwarding Detection) est active entre loxilb et les routeurs pour detecter une panne en < 1 seconde (vs 30-90s avec les timers BGP standard) :

```
Routeur ←──BFD 100ms──► loxilb-1  (OK)
Routeur ←──BFD 100ms──► loxilb-2  (OK)

loxilb-1 tombe :
  BFD timeout (300ms) → routeur retire la route → tout le trafic → loxilb-2
```

### Scalabilite horizontale

Ajouter un 3eme loxilb = juste un nouveau peer BGP, zero reconfiguration des routeurs :

```
routeur reçoit VIP/32 depuis loxilb-1, loxilb-2, loxilb-3
→ ECMP automatique a 3 : chaque loxilb prend ~33% du trafic
```

C'est le meme principe que les hyperscalers (Google Maglev, Meta Katran) et les architectures 5G/telco pour lesquelles loxilb a ete concu (SCTP multi-homing).

---

### Comparaison In-Cluster vs External

| Aspect                       | In-Cluster (RKE2/K3s) | External k3d          | External VM Vagrant                    |
| ---------------------------- | --------------------- | --------------------- | -------------------------------------- |
| **Deploiement LoxiLB**       | DaemonSet cluster     | Container Docker hote | Container Docker VM dedice             |
| **Connectivite kube-loxilb** | DNS interne           | IP bridge Docker      | IP eth1 VM (`loxiURL`)                 |
| **eBPF**                     | Sur interfaces nodes  | Sur interfaces hote   | Sur eth1 VM uniquement (`--whitelist`) |
| **Multus requis**            | Avec Cilium           | Non                   | Non                                    |
| **setLBMode**                | 0 ou 1                | 1 (onearm)            | 0 (DNAT + BGP routing)                 |
| **VIP range**                | IP reseau physique    | IP sous-reseau Docker | IP reseau Vagrant (`192.168.121.x`)    |
| **BGP**                      | Optionnel             | N/A                   | Requis (PodCIDR routing)               |

## Configuration

### Provider Selection

Le provider LoadBalancer est configuré dans `config/config.yaml`:

```yaml
features:
  loadBalancer:
    enabled: true
    provider: "loxilb" # metallb | cilium | loxilb
    mode: "l2" # l2 | bgp
    pools:
      default:
        range: "192.168.121.220-192.168.121.250"
```

### Configuration Spécifique

Les fichiers `config/dev.yaml` et `config/prod.yaml` permettent de configurer:

| Paramètre                | Description                           | Défaut                          |
| ------------------------ | ------------------------------------- | ------------------------------- |
| `loxilb.loxilbImage`     | Image loxilb                          | `ghcr.io/loxilb-io/loxilb`      |
| `loxilb.loxilbTag`       | Version de l'image loxilb             | `v0.9.8`                        |
| `loxilb.kubeLoxilbImage` | Image kube-loxilb                     | `ghcr.io/loxilb-io/kube-loxilb` |
| `loxilb.kubeLoxilbTag`   | Version de l'image kube-loxilb        | `v0.9.8`                        |
| `loxilb.setLBMode`       | Mode LB (0=DNAT, 1=onearm, 2=fullNAT) | `0`                             |
| `loxilb.loxiURL`         | URL API loxilb externe (k3d only)     | `http://172.18.0.1:11111`       |

### Modes de Load Balancing

| Mode        | Valeur | Description                       |
| ----------- | ------ | --------------------------------- |
| **DNAT**    | `0`    | Destination NAT standard (défaut) |
| **One-ARM** | `1`    | Mode interface unique             |
| **FullNAT** | `2`    | Full NAT avec réécriture source   |

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
  loadBalancerClass: loxilb.io/loxilb # Requis pour LoxiLB
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

**Note**: Sans `loadBalancerClass`, les Services ne seront pas pris en charge par LoxiLB.

## Annotations de Service

LoxiLB supporte plusieurs annotations pour personnaliser le comportement:

| Annotation            | Description             | Valeurs                                      |
| --------------------- | ----------------------- | -------------------------------------------- |
| `loxilb.io/lbmode`    | Mode LB par service     | `default`, `onearm`, `fullnat`, `dsr`        |
| `loxilb.io/liveness`  | Health probing          | `yes`, `no`                                  |
| `loxilb.io/epselect`  | Algorithme de sélection | `roundrobin`, `hash`, `persist`, `leastconn` |
| `loxilb.io/probetype` | Type de health check    | `tcp`, `udp`, `http`, `https`                |
| `loxilb.io/probeport` | Port du health check    | Port number                                  |
| `loxilb.io/staticIP`  | IP externe fixe         | IP address                                   |

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

| Aspect            | LoxiLB       | MetalLB            | Cilium LB-IPAM      |
| ----------------- | ------------ | ------------------ | ------------------- |
| **Performance**   | Haute (eBPF) | Modérée (iptables) | Haute (eBPF)        |
| **DSR Support**   | ✅           | ❌                 | ✅                  |
| **L7 Natif**      | ✅           | ❌                 | Via Envoy           |
| **CNI Required**  | Non          | Non                | Cilium              |
| **VM Compatible** | ✅           | ✅                 | ✅ (config requise) |
| **Maturité**      | CNCF Sandbox | Mature             | Mature              |

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

### Solution : Multus CNI + Exclusion eth1 de Cilium

La coexistence de LoxiLB et Cilium nécessite **deux configurations** :

#### 1. Multus CNI pour isoler le trafic LoxiLB

Selon la [documentation officielle](https://docs.loxilb.io/latest/cilium-incluster/), LoxiLB doit utiliser une interface secondaire via Multus/macvlan.

#### 2. Exclusion d'eth1 des devices Cilium (automatique)

**Problème découvert** : Même avec Multus, si Cilium a des hooks eBPF sur l'interface parente de macvlan (eth1), il intercepte le trafic **avant** qu'il n'atteigne LoxiLB et fait le DNAT lui-même.

```bash
# tcpdump sur l'interface macvlan du pod LoxiLB montrait :
192.168.121.1.42858 > 10.42.0.101.80  # Déjà DNAT'é par Cilium !
# Au lieu de :
192.168.121.1.42858 > 192.168.121.210.80  # L'IP originale de la VIP
```

**Solution** : Le script `configure_cilium.sh` exclut automatiquement `eth1` des devices Cilium quand `LB_PROVIDER=loxilb` :

```bash
# vagrant/scripts/configure_cilium.sh
elif [ "$LB_PROVIDER" = "loxilb" ]; then
  CILIUM_DEVICES_YAML=$'    - eth0'  # eth1 exclu !
```

Cela désactive les hooks eBPF de Cilium sur eth1, permettant au trafic macvlan d'atteindre LoxiLB directement.

#### Configuration complète

1. **Configurer `config/config.yaml`** :

   ```yaml
   features:
     loadBalancer:
       enabled: true
       provider: "loxilb"
       mode: "l2"
       pools:
         default:
           range: "192.168.121.220-192.168.121.250"
     cni:
       multus:
         enabled: true
   ```

2. **Recréer le cluster** :
   ```bash
   make vagrant-dev-destroy && make dev-full
   ```

Le script de déploiement :

- Configure RKE2 avec `cni: [multus, cilium]`
- Configure Cilium avec `devices: [eth0]` seulement (eth1 exclu)
- Déploie l'ApplicationSet `multus` avec les NetworkAttachmentDefinitions
- Utilise automatiquement `loxilb-multus` au lieu de `loxilb` (hostNetwork: false + annotation Multus)

Cette configuration isole le trafic LoxiLB dans des interfaces distinctes de celles gérées par Cilium.

#### Vérification de la configuration

```bash
# Vérifier que Cilium n'a pas de hooks sur eth1
ssh vagrant@<node-ip> "sudo bpftool net show | grep eth1"
# Devrait être vide si LB_PROVIDER=loxilb

# Vérifier les hooks Cilium (seulement eth0)
ssh vagrant@<node-ip> "sudo bpftool net show | head -10"
# eth0(2) tcx/ingress cil_from_netdev ...

# Vérifier les compteurs LoxiLB
kubectl exec -n kube-system -l app=loxilb-app -- loxicmd get lb -o wide
# COUNTERS devrait montrer du trafic (pas 0:0)
```

### Alternatives recommandées

Si vous utilisez Cilium comme CNI, considérez ces alternatives :

| Alternative         | Avantages                         | Inconvénients                              |
| ------------------- | --------------------------------- | ------------------------------------------ |
| **MetalLB**         | Simple, mature, compatible Cilium | Pas de DSR, performance moindre            |
| **Cilium LB-IPAM**  | Natif Cilium, haute performance   | Interface L2 doit être dans devices Cilium |
| **LoxiLB + Multus** | Toutes les fonctionnalités LoxiLB | Recréation cluster requise                 |

### Vérification de la compatibilité

```bash
# Vérifier si Cilium XDP est attaché
kubectl exec -n kube-system ds/cilium -- ip link show eth0 | grep xdp
# prog/xdp id XXXX = Cilium XDP actif, conflit probable

# Vérifier les erreurs loxilb
kubectl logs -n kube-system -l app=loxilb-app | grep -i "failed\|error"
```

## Troubleshooting

### Mode External VM Vagrant - Diagnostic ARP/GARP

#### Identifier si les VIPs ont la bonne MAC (eth1)

```bash
# Sur l'hote Vagrant (pas dans la VM)
# Verifier l'ARP cache pour les VIPs
ip neigh show 192.168.121.201   # DNS VIP
ip neigh show 192.168.121.210   # HTTPS VIP

# Les deux doivent pointer vers la meme MAC (eth1 de la VM loxilb)
# Obtenir la MAC de eth1 depuis la VM
vagrant ssh k8s-dev-loxilb1 -- ip link show eth1 | grep ether

# Si une VIP pointe vers eth0 MAC → probleme IfaSelectAny() loxilb
# (voir section "Probleme dual-interface ARP/GARP")
```

#### Verifier les fixes eth0

```bash
# Verifier que eth0 est en /32 (pas /24)
vagrant ssh k8s-dev-loxilb1 -- ip addr show eth0
# Attendu: inet 192.168.121.5/32 brd 192.168.121.5 scope global eth0

# Verifier le service systemd
vagrant ssh k8s-dev-loxilb1 -- systemctl status loxilb-eth0-fix.service

# Verifier arp_ignore
vagrant ssh k8s-dev-loxilb1 -- sysctl net.ipv4.conf.eth0.arp_ignore
# Attendu: net.ipv4.conf.eth0.arp_ignore = 1

# Verifier --whitelist dans les args du container
vagrant ssh k8s-dev-loxilb1 -- docker inspect loxilb-external | grep -A5 Cmd
```

#### Forcer un nouveau GARP apres correction

> **Attention** : `docker restart` peut laisser `tmac_map` vide (voir section "tmac_map vide apres docker restart"). Privilegier un reboot VM (`vagrant reload`) plutot qu'un restart conteneur.

```bash
# Methode recommandee : reboot VM (reattache eBPF proprement)
LB_PROVIDER=loxilb LB_MODE=bgp vagrant reload k8s-dev-loxilb1

# Methode risquee (peut casser tmac_map) :
# vagrant ssh k8s-dev-loxilb1 -- docker restart loxilb-external

# Verifier l'ARP cache apres reboot
ip neigh show 192.168.121.210
```

#### Compteurs LoxiLB a 0

```bash
# Verifier les compteurs depuis le master
kubectl exec -n kube-system deploy/kube-loxilb -- loxicmd get lb -o wide

# Si COUNTERS=0:0, verifier que le trafic arrive bien sur eth1 (pas eth0)
vagrant ssh k8s-dev-loxilb1 -- tcpdump -i eth1 -n 'port 443' -c 10 &
curl -sk https://argocd.k8s.lan > /dev/null

# Si rien sur eth1 mais trafic sur eth0 → ARP pointe vers eth0 MAC
vagrant ssh k8s-dev-loxilb1 -- tcpdump -i eth0 -n 'port 443' -c 5
```

#### Logs utiles loxilb

```bash
# Erreur "subnet-route add error" = eth0 a ajoute /24 avant eth1
vagrant ssh k8s-dev-loxilb1 -- docker logs loxilb-external 2>&1 | grep -E "subnet-route|eth0|eth1|IfaSelect"

# GARP envoye avec quelle interface
vagrant ssh k8s-dev-loxilb1 -- docker logs loxilb-external 2>&1 | grep -i "garp\|adv"
```

### Port 443 absent apres demarrage (bug kube-loxilb multi-port)

**Symptome** : apres un `argocd app sync` ou un premier deploiement, `loxicmd get lb` montre `.210:80` mais **`.210:443` est absent** (ou l'inverse). Les regles LB multi-port sont incompletes.

**Cause** : kube-loxilb traite les endpoints en parallele. Si les endpoints d'un Service multi-port arrivent dans un ordre different de celui attendu, la regle pour le second port peut etre ignoree silencieusement (race condition a l'initialisation).

**Diagnostic** :

```bash
# Verifier les regles LB presentes dans loxilb
kubectl exec -n kube-system deploy/kube-loxilb -- loxicmd get lb -o wide
# Si .210:443 est absent mais .210:80 present → bug multi-port

# Verifier les logs kube-loxilb pour des erreurs sur le port 443
kubectl logs -n kube-system -l app=kube-loxilb-app --tail=50 | grep -i "443\|error\|failed"
```

**Workaround** : redemarrer kube-loxilb force une re-synchronisation complete de tous les Services :

```bash
kubectl rollout restart deployment/kube-loxilb -n kube-system
kubectl rollout status deployment/kube-loxilb -n kube-system

# Verifier que les deux ports sont maintenant presents
kubectl exec -n kube-system deploy/kube-loxilb -- loxicmd get lb -o wide
# Attendu:
#   192.168.121.210:80   TCP  ...
#   192.168.121.210:443  TCP  ...
```

---

### BGP peering ne s'etablit pas

```bash
# Verifier l'etat de la session BGP
vagrant ssh k8s-dev-loxilb1 -- docker exec loxilb-external gobgp neighbor
# Si "Active" au lieu de "Established" → TCP 179 bloque

# Verifier que Cilium ecoute sur 179
kubectl exec -n kube-system ds/cilium -- ss -tlnp | grep 179

# Verifier la CiliumBGPPeeringPolicy
kubectl get ciliumbgppeeringpolicy -o yaml

# Verifier les network policies (loxilb-bgp-host-ingress)
kubectl get ciliumclusterwidenetworkpolicy loxilb-bgp-host-ingress -o yaml

# Tester la connectivite TCP 179 depuis la VM loxilb vers le master
vagrant ssh k8s-dev-loxilb1 -- nc -zv 192.168.121.50 179
```

### Flood eBPF lors du failover FRR (mode BGP)

**Symptome** : quand une VM FRR est arretee (`virsh shutdown`), le HTTPS via VIP tombe a ~10-20% de succes. Ping vers les autres VMs montre 40-60% de perte.

**Cause** : les SYN BGP (TCP 179) des loxilb vers le FRR mort deviennent unknown-unicast sur le bridge (MAC du FRR disparu de la FDB). Le bridge les flood vers tous les ports. L'eBPF de chaque loxilb re-forwarde ces paquets, creant une boucle de feedback a 80-100k+ pps qui sature les TAP queues.

**Diagnostic** :

```bash
# Mesurer le debit sur un port loxilb (> 1000 pps = flood)
RX1=$(cat /sys/class/net/vnet13/statistics/rx_packets); sleep 1
RX2=$(cat /sys/class/net/vnet13/statistics/rx_packets)
echo "$(( RX2 - RX1 )) pps"

# Capturer les paquets du flood
vagrant ssh k8s-dev-loxilb1 -- sudo docker exec loxilb-external \
  tcpdump -i eth1 -nn -c 20 2>/dev/null
# Attendu si flood: SYN TCP 179 vers l'IP du FRR mort
```

**Fix** : desactiver le flooding unknown-unicast sur les ports bridge loxilb :

```bash
sudo vagrant/scripts/configure-loxilb-bridge-ports.sh k8s-dev-loxilb1
sudo vagrant/scripts/configure-loxilb-bridge-ports.sh k8s-dev-loxilb2
sudo vagrant/scripts/configure-loxilb-bridge-ports.sh k8s-dev-loxilb3
```

Ce fix est applique automatiquement via un Vagrant trigger apres `vagrant up`.

> **Note** : le flood off est necessaire en mode actif-actif ET actif-standby. Meme en ECMP, quand un peer BGP tombe, les SYN TCP 179 vers son IP deviennent unknown-unicast et declenchent la boucle de feedback entre les instances loxilb restantes.

> **Important** : utiliser `LB_PROVIDER=loxilb LB_MODE=bgp vagrant up` au lieu de `virsh start` pour relancer une VM loxilb. Le Vagrant trigger qui applique le flood off ne s'execute qu'avec `vagrant up`. Un `virsh start` restaure la VM mais sans le flood off sur ses ports bridge.

### tmac_map vide apres docker restart/recreate (bug loxilb)

**Symptome** : apres un `docker restart loxilb-external` ou `docker rm -f && docker run`, **100% des connexions** via cette instance echouent (HTTP 000/timeout). Les autres instances ECMP fonctionnent normalement.

**Cause racine** : `tmac_map` vide. Cette map eBPF contient la MAC de l'interface whitelist (eth1). C'est la **premiere map consultee** par le programme TC ingress — si la MAC destination du paquet ne correspond a aucune entree de `tmac_map`, le paquet est bypass (`TC_ACT_OK`) → le kernel l'envoie sur la stack normale → RST (pas de socket).

Lors d'un `docker restart`, le hook TC eBPF ne se detache pas proprement :

```
ERROR common_libbpf.c:94: tc: bpf hook destroy failed for eth1:0
```

Le nouveau programme eBPF s'attache, mais `tmac_map` n'est pas repeuplee avec la MAC de eth1.

**Diagnostic** :

```bash
# Verifier tmac_map (doit contenir la MAC de eth1)
vagrant ssh k8s-dev-loxilb1 -- sudo docker exec loxilb-external ntc -a tmac_map
# Si vide → bug confirme

# Comparer avec une instance fonctionnelle
vagrant ssh k8s-dev-loxilb2 -- sudo docker exec loxilb-external ntc -a tmac_map
# Doit montrer: key=<eth1_mac> value=...

# Verifier nat_map (regles LB) pour comparaison
vagrant ssh k8s-dev-loxilb1 -- sudo docker exec loxilb-external ntc -a nat_map
# nat_map peut etre correct meme si tmac_map est vide
```

**Workaround** : un **reboot complet de la VM** est necessaire. Un simple `docker restart` ou `docker rm -f && docker run` ne suffit pas.

```bash
# Depuis l'hote Vagrant
vagrant reload k8s-dev-loxilb1
# Ou: virsh reboot k8s-dev-loxilb1

# Apres reboot, verifier tmac_map
vagrant ssh k8s-dev-loxilb1 -- sudo docker exec loxilb-external ntc -a tmac_map
# Doit etre non-vide
```

> **Bug upstream** : a reporter sur [loxilb-io/loxilb](https://github.com/loxilb-io/loxilb/issues). Le hook TC eBPF ne se detache pas proprement lors de l'arret du conteneur, et `tmac_map` n'est pas repeuplee au redemarrage.

### Mode External (k3d) - Problemes courants

#### Container LoxiLB ne demarre pas

```bash
# Verifier les logs du container
docker logs loxilb-external

# Verifier que le container tourne avec --net=host
docker inspect loxilb-external --format '{{.HostConfig.NetworkMode}}'
# Attendu: host

# Verifier que le port 11111 est accessible
curl http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all
```

#### kube-loxilb ne peut pas joindre l'API LoxiLB externe

```bash
# Verifier l'IP du bridge k3d
docker network inspect k3d-<cluster-name> --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'

# Tester la connectivite depuis un pod k3d
kubectl run -it --rm test --image=busybox --restart=Never -- \
  wget -q -O- http://172.18.0.1:11111/netlox/v1/config/loadbalancer/all

# Verifier la configuration loxiURL dans le deployment
kubectl get deployment -n kube-system kube-loxilb -o yaml | grep loxiURL
```

#### initContainer bloque (external mode)

L'initContainer attend que l'API LoxiLB soit accessible via HTTP. Si bloque :

```bash
# Verifier les logs de l'initContainer
kubectl logs -n kube-system -l app=kube-loxilb-app -c wait-for-loxilb

# Verifier que loxilb-external tourne sur l'hote AVANT de deployer l'appset
./deploy/argocd/apps/loxilb/scripts/start-loxilb-external.sh --status
```

#### Services sans IP externe (mode external)

```bash
# Verifier les logs kube-loxilb
kubectl logs -n kube-system -l app=kube-loxilb-app -f

# Verifier que loxilb recoit les requetes (depuis l'hote)
curl http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all

# Verifier que le VIP range est dans le sous-reseau k3d
# Le range doit etre dans 172.18.0.0/16 (ou le CIDR du bridge k3d)
docker network inspect k3d-<cluster> | grep Subnet
```

#### LoxiLB externe survit au redemarrage du cluster k3d

Le container LoxiLB est configure avec `--restart unless-stopped`. Il redemarrera automatiquement avec Docker, mais ses regles LB seront perdues. kube-loxilb les re-programmera automatiquement a la reconnexion.

```bash
# Apres recreer le cluster k3d, kube-loxilb se reconnecte automatiquement
# Verifier que les regles sont bien reprogrammees
curl http://127.0.0.1:11111/netlox/v1/config/loadbalancer/all
```

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

## Mode External multi-serveurs (HA)

En mode externe, il est possible de configurer plusieurs instances loxilb pour la haute disponibilité. kube-loxilb supporte nativement plusieurs URLs via `--loxiURL=url1,url2,...`.

### Modes HA : actif-actif vs actif-standby

loxilb supporte deux modes HA, contrôlés par le flag `--setRoles` de kube-loxilb :

| Aspect | Actif-actif (ECMP) | Actif-standby |
| --- | --- | --- |
| **Flag kube-loxilb** | Pas de `--setRoles` | `--setRoles=0.0.0.0` |
| **HA State** | `NOT_DEFINED` sur toutes les instances | `MASTER` sur 1, `BACKUP` sur les autres |
| **BGP MED** | `MED=0` identique sur toutes les instances | `MED=10` (MASTER), `MED=70` (BACKUP) |
| **Distribution trafic** | ECMP hash par flow via FRR (`maximum-paths`) | Tout le trafic vers le MASTER uniquement |
| **Failover** | Automatique (FRR retire le next-hop mort) | kube-loxilb élit un nouveau MASTER |
| **Temps de failover** | BGP hold timer (ex: 9s avec timers 3 9) | BGP hold timer + élection MASTER (~35s) |
| **Utilisation réseau** | Toutes les instances traitent du trafic | BACKUP(s) inactif(s) sauf failover |

#### Actif-actif (recommandé en mode BGP)

C'est le mode par défaut quand `--setRoles` est **absent** des args kube-loxilb. Toutes les instances annoncent les VIPs en BGP avec le même MED (0). FRR distribue le trafic en ECMP (hash par 5-tuple : src/dst IP + src/dst port + proto).

```
                  FRR BGP RIB (show ip route bgp)
                  B>* 192.168.121.210/32 [20/0] via 192.168.121.40, eth1, weight 1
                                                 via 192.168.121.41, eth1, weight 1
                                                 via 192.168.121.42, eth1, weight 1
```

Le `NOT_DEFINED` affiché par `loxicmd get ha` est le comportement normal : sans `--setRoles`, kube-loxilb n'envoie pas de `CIStatusModel` aux instances loxilb, donc aucun rôle MASTER/BACKUP n'est assigné. Chaque instance traite le trafic qu'elle reçoit via ECMP de manière indépendante.

**Code source kube-loxilb** (`cmd/loxilb-agent/agent.go`) : la fonction `SelectInstLoxiLBRoles()` n'est appelée que si `networkConfig.SetRoles != ""`. Sans ce flag, le cycle d'élection MASTER/BACKUP est entièrement désactivé.

```yaml
# ApplicationSet kube-loxilb args (actif-actif, pas de --setRoles) :
args:
  - --loxiURL=http://192.168.121.40:11111,http://...41:11111,http://...42:11111
  - --cidrPools=defaultPool=192.168.121.200-192.168.121.220
  - --setLBMode=1
  - --setBGP=65002
  - --extBGPPeers=192.168.121.45:65000,192.168.121.46:65000
  - --noZoneName
  # PAS de --setRoles → actif-actif
```

#### Actif-standby

Activé en ajoutant `--setRoles=0.0.0.0` aux args kube-loxilb. Une seule instance est élue MASTER (MED=10), les autres sont BACKUP (MED=70). Le trafic est orienté vers le MASTER par le routeur FRR grâce au MED plus faible.

**Inconvénients** :
- Les instances BACKUP sont inutilisées (gaspillage de ressources)
- Le failover est plus lent car il combine la détection BGP + l'élection d'un nouveau MASTER par kube-loxilb
- Le comportement de `kube-loxilb` après un restart de conteneur peut être imprévisible (l'état HA affiché peut rester `NOT_DEFINED` tant que kube-loxilb ne re-synchronise pas)

### Configuration multi-instances

Le Vagrantfile dérive automatiquement le nombre de VMs depuis la liste `loxilb.loxiURL`. Il suffit de modifier **un seul fichier** :

**`deploy/argocd/apps/loxilb/config/dev.yaml`**

```yaml
loxilb:
  mode: "external"
  loxiURL:
    - "http://192.168.121.40:11111"   # 1re instance (VM k8s-dev-loxilb1)
    - "http://192.168.121.41:11111"   # 2e instance (VM k8s-dev-loxilb2)
    - "http://192.168.121.42:11111"   # 3e instance (VM k8s-dev-loxilb3)
  setLBMode: 1
  bgp:
    enabled: true
    localASN: 65002
    extBGPPeers: "192.168.121.50:64512"
```

**Lancer `vagrant up`**

```bash
LB_PROVIDER=loxilb LB_MODE=bgp make vagrant-dev-up
# Crée automatiquement : k8s-dev-loxilb1 (.40), k8s-dev-loxilb2 (.41), k8s-dev-loxilb3 (.42)
```

### Attribution des IPs

| Instance | VM Vagrant         | IP eth1             |
| -------- | ------------------ | ------------------- |
| 1        | `k8s-dev-loxilb1`   | `192.168.121.40`    |
| 2        | `k8s-dev-loxilb2`  | `192.168.121.41`    |
| 3        | `k8s-dev-loxilb3`  | `192.168.121.42`    |

### Effet sur les manifests générés

- **`--loxiURL`** : toutes les URLs jointes par virgule → `--loxiURL=http://...40:11111,http://...41:11111`
- **initContainer** `LOXILB_URL` : seule la 1re URL (health-check au démarrage)
- **Egress policies** (Cilium/Calico) : `toCIDR`/`nets` remplace le tableau complet avec N CIDRs `/32`
- **Ingress policies** (pod + host BGP) : idem, `fromCIDR`/`nets` avec N entrées
- **BGP direct peers** (Cilium, mode non-bgp) : génère N peers `loxilb-direct-0`, `loxilb-direct-1`, ...
- **BGP peer Calico** : seule la 1re IP (limitation Calico : un seul `BGPPeer` par ressource)

### Comportement à 1 instance

Avec `$loxilb_count = 1` et une seule URL, le comportement est **identique à l'ancien scalaire**.

### Vérification ECMP (mode actif-actif)

```bash
# 1. Vérifier que toutes les instances annoncent les VIPs avec MED=0
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show bgp ipv4 unicast 192.168.121.210/32"
# Paths: (3 available, ..., multipath)
#   192.168.121.40 ... metric 0, valid, external, multipath
#   192.168.121.41 ... metric 0, valid, external, multipath
#   192.168.121.42 ... metric 0, valid, external, multipath

# 2. Vérifier la table de routage FRR (3 next-hops ECMP)
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show ip route 192.168.121.210"
# B>* 192.168.121.210/32 ... via 192.168.121.40, eth1, weight 1
#                            via 192.168.121.41, eth1, weight 1
#                            via 192.168.121.42, eth1, weight 1

# 3. Vérifier les compteurs LB (trafic distribué sur les 3)
for ip in 40 41 42; do
  echo "=== loxilb (.${ip}) ==="
  ssh vagrant@192.168.121.${ip} "sudo docker exec loxilb-external loxicmd get lb -o wide" \
    | grep 443
done

# 4. Vérifier les sessions BGP sur chaque instance
for ip in 40 41 42; do
  echo "=== loxilb (.${ip}) ==="
  ssh vagrant@192.168.121.${ip} "sudo docker exec loxilb-external loxicmd get bgpneigh"
done
```

---

## Références

- [Documentation LoxiLB](https://docs.loxilb.io/latest/)
- [GitHub kube-loxilb](https://github.com/loxilb-io/kube-loxilb)
- [Manifests officiels](https://github.com/loxilb-io/kube-loxilb/tree/main/manifest/in-cluster)
- [GitHub loxilb](https://github.com/loxilb-io/loxilb)
- [LoxiLB + Cilium Integration](https://docs.loxilb.io/latest/cilium-incluster/)
