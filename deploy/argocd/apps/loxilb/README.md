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
│  │  VM k8s-dev-loxilb                       │                           │
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

Le Vagrantfile crée la VM `k8s-dev-loxilb` et appelle `provision-loxilb-external.sh` automatiquement quand `LB_PROVIDER=loxilb` et `loxilb.mode: "external"` dans `config/dev.yaml`.

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

**Persistance** : Les fixes 1 et 2 sont automatiquement appliques au boot via un service systemd `loxilb-eth0-fix.service` (avec `Before=docker.service`) et `/etc/sysctl.d/`.

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

Le BGP est utilise pour que Cilium **advertise les routes PodCIDR vers loxilb**. Sans cela, loxilb peut DNAT le trafic vers l'IP d'un pod mais ne sait pas router vers `10.42.0.0/16`.

> **Note** : `loadBalancer.mode` reste `l2` (ARP/GARP pour les VIPs). Le BGP sert **uniquement** au routage PodCIDR, pas a l'annonce des VIPs.

### Architecture BGP

```
LoxiLB VM (ASN 65002)          Cluster RKE2 (ASN 64512 = Cilium)
192.168.121.40                  192.168.121.50 (master)

  GoBGP (--bgp flag)    ←eBGP→  Cilium bgpControlPlane
  kube-loxilb configures         CiliumBGPPeeringPolicy:
  peers via API REST:              - exportPodCIDR: true
    --setBGP=65002                 - neighbors: loxilb VM
    --extBGPPeers=...:64512

Routes apprises par loxilb:
  10.42.0.0/24 via 192.168.121.50 (master node)
```

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

```bash
# Session BGP etablie
docker exec loxilb-external gobgp neighbor
# Peer          AS      Up/Down  State       |#Received  Accepted
# 192.168.121.50 64512  00:27:34 Established |        1         1

# Routes PodCIDR apprises par loxilb
docker exec loxilb-external gobgp global rib
# Network         Next Hop      AS_PATH  Age        Attrs
# 10.42.0.0/24   192.168.121.50 64512   00:27:34   [{Origin: i}]

# CiliumBGPPeeringPolicy
kubectl get ciliumbgppeeringpolicy loxilb-external-bgp -o yaml

# Test end-to-end (DNS via VIP)
dig @192.168.121.201 google.com
```

---

## Architecture production : BGP pur avec routeurs physiques

En environnement client avec des routeurs BGP physiques (Cisco, Juniper, Arista), le mode L2/GARP est remplace par du **BGP pur actif/actif**. C'est l'architecture de reference pour la haute disponibilite et la scalabilite.

```
                        ┌──────────────────────────────────────────┐
                        │   Routeurs physiques   ASN 65000         │
                        │   (Cisco / Juniper / Arista)             │
                        │                                          │
                        │   VIP 10.0.1.0/24 → ECMP                │
                        │     next-hop 10.0.0.1  (loxilb-1)       │
                        │     next-hop 10.0.0.2  (loxilb-2)       │
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
                        │   Cluster Kubernetes (Cilium)           │
                        │   ASN 64512                             │
                        │                                         │
                        │   Advertise vers loxilb-1 et loxilb-2: │
                        │     PodCIDR 10.42.0.0/16               │
                        │                                         │
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

| Aspect | Vagrant (lab) | Production (routeurs BGP) |
|--------|--------------|---------------------------|
| **VIP announcement** | GARP (L2) | BGP (L3) |
| **Nombre loxilb** | 1 VM | 2+ (actif/actif) |
| **Failover** | Manuel / redemarrage | Automatique via BFD (< 1s) |
| **ECMP** | Non | Oui (routeur hash par flow) |
| **ARP/GARP** | Requis | Non (routage L3 pur) |
| **Scalabilite** | Limitee | Ajouter un peer BGP = scale-out |
| **Routeur upstream** | virbr1 (pas BGP) | Cisco/Juniper/Arista/FRR |

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
vagrant ssh k8s-dev-loxilb -- ip link show eth1 | grep ether

# Si une VIP pointe vers eth0 MAC → probleme IfaSelectAny() loxilb
# (voir section "Probleme dual-interface ARP/GARP")
```

#### Verifier les fixes eth0

```bash
# Verifier que eth0 est en /32 (pas /24)
vagrant ssh k8s-dev-loxilb -- ip addr show eth0
# Attendu: inet 192.168.121.5/32 brd 192.168.121.5 scope global eth0

# Verifier le service systemd
vagrant ssh k8s-dev-loxilb -- systemctl status loxilb-eth0-fix.service

# Verifier arp_ignore
vagrant ssh k8s-dev-loxilb -- sysctl net.ipv4.conf.eth0.arp_ignore
# Attendu: net.ipv4.conf.eth0.arp_ignore = 1

# Verifier --whitelist dans les args du container
vagrant ssh k8s-dev-loxilb -- docker inspect loxilb-external | grep -A5 Cmd
```

#### Forcer un nouveau GARP apres correction

```bash
# Redemarrer loxilb pour qu'il re-envoie les GARPs avec la bonne MAC
vagrant ssh k8s-dev-loxilb -- docker restart loxilb-external

# Attendre ~10s puis verifier l'ARP cache
sleep 10
ip neigh show 192.168.121.210
```

#### Compteurs LoxiLB a 0

```bash
# Verifier les compteurs depuis le master
kubectl exec -n kube-system deploy/kube-loxilb -- loxicmd get lb -o wide

# Si COUNTERS=0:0, verifier que le trafic arrive bien sur eth1 (pas eth0)
vagrant ssh k8s-dev-loxilb -- tcpdump -i eth1 -n 'port 443' -c 10 &
curl -sk https://argocd.k8s.lan > /dev/null

# Si rien sur eth1 mais trafic sur eth0 → ARP pointe vers eth0 MAC
vagrant ssh k8s-dev-loxilb -- tcpdump -i eth0 -n 'port 443' -c 5
```

#### Logs utiles loxilb

```bash
# Erreur "subnet-route add error" = eth0 a ajoute /24 avant eth1
vagrant ssh k8s-dev-loxilb -- docker logs loxilb-external 2>&1 | grep -E "subnet-route|eth0|eth1|IfaSelect"

# GARP envoye avec quelle interface
vagrant ssh k8s-dev-loxilb -- docker logs loxilb-external 2>&1 | grep -i "garp\|adv"
```

### BGP peering ne s'etablit pas

```bash
# Verifier l'etat de la session BGP
vagrant ssh k8s-dev-loxilb -- docker exec loxilb-external gobgp neighbor
# Si "Active" au lieu de "Established" → TCP 179 bloque

# Verifier que Cilium ecoute sur 179
kubectl exec -n kube-system ds/cilium -- ss -tlnp | grep 179

# Verifier la CiliumBGPPeeringPolicy
kubectl get ciliumbgppeeringpolicy -o yaml

# Verifier les network policies (loxilb-bgp-host-ingress)
kubectl get ciliumclusterwidenetworkpolicy loxilb-bgp-host-ingress -o yaml

# Tester la connectivite TCP 179 depuis la VM loxilb vers le master
vagrant ssh k8s-dev-loxilb -- nc -zv 192.168.121.50 179
```

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

## Références

- [Documentation LoxiLB](https://docs.loxilb.io/latest/)
- [GitHub kube-loxilb](https://github.com/loxilb-io/kube-loxilb)
- [Manifests officiels](https://github.com/loxilb-io/kube-loxilb/tree/main/manifest/in-cluster)
- [GitHub loxilb](https://github.com/loxilb-io/loxilb)
- [LoxiLB + Cilium Integration](https://docs.loxilb.io/latest/cilium-incluster/)
