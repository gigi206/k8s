# FRR — Routeur BGP Upstream

FRR (Free Range Routing) est un routeur BGP open-source qui simule un **routeur physique upstream** en mode BGP pur (`loadBalancer.mode: bgp`). Il est déployé comme VM Vagrant dédiée (`k8s-<cluster>-frr`) pour éliminer les GARP et remplacer les annonces L2 par du routage BGP pur.

## Rôle

FRR est **générique** — il n'est pas spécifique à LoxiLB. Son rôle est de peer avec tous les composants BGP du cluster :

- **LoxiLB** (ASN 65002) → FRR apprend les VIP `/32` routes
- **Cilium** (ASN 64512) → FRR apprend les PodCIDR routes
- **Proxy-ARP sur eth1** → activé mais **inactif en flat L2** (voir [Control Plane vs Data Plane](#control-plane-vs-data-plane))

## Topologie BGP Mode vs L2 Mode

```
# Mode BGP (loadBalancer.mode: bgp)
loxilb (65002) <-eBGP-> FRR (65000) <-eBGP-> Cilium (64512)
                                     ↑
                              Proxy-ARP eth1
                              (répond pour VIPs)

# Mode L2 actuel (loadBalancer.mode: l2)
loxilb (65002) <-eBGP-> Cilium (64512)  +  GARP depuis loxilb
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Hote Vagrant (Linux)   192.168.121.0/24 (libvirt bridge virbr1)        │
│                                                                         │
│  ┌──────────────────────────────────────────┐                           │
│  │  VM k8s-dev-frr1                          │                           │
│  │  eth0: 192.168.121.5/...  (Vagrant mgmt) │                           │
│  │  eth1: 192.168.121.45/24  (FRR BGP WAN)  │                           │
│  │                                          │                           │
│  │  FRR (ASN 65000)                         │                           │
│  │  - eBGP peer loxilb .40 (ASN 65002)      │                           │
│  │  - eBGP peer cilium  .50 (ASN 64512)     │                           │
│  │  - proxy_arp=1 sur eth1                  │                           │
│  │  - ip_forward=1                          │                           │
│  └──────────────────────────────────────────┘                           │
│         ↑ eBGP                    ↑ eBGP                                │
│  ┌──────┴──────────┐    ┌─────────┴──────────────────────────────┐      │
│  │ VM k8s-dev-     │    │  Cluster RKE2                           │      │
│  │ loxilb (.40)    │    │                                         │      │
│  │                 │    │  Master (.50) - Cilium (ASN 64512)      │      │
│  │ GoBGP (65002)   │    │  bgpControlPlane.enabled: true          │      │
│  │ --bgp           │    │  Advertise PodCIDR 10.42.0.0/24         │      │
│  │ Advertise VIPs  │    │                                         │      │
│  └─────────────────┘    └─────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Configuration

### Activation

Pour passer en mode BGP pur, modifier `deploy/argocd/config/config.yaml` :

```yaml
features:
  loadBalancer:
    mode: "bgp"   # l2 -> bgp
```

Le Vagrantfile créera automatiquement la VM `k8s-<cluster>-frr` avec `lb_mode=bgp`.

### Paramètres FRR

```yaml
# deploy/argocd/config/config.yaml
frr:
  asn: 65000              # ASN du routeur FRR (eBGP avec loxilb et Cilium)
  ip: "192.168.121.45"    # IP eth1 de la VM FRR
```

### Paramètres LoxiLB en mode BGP

```yaml
# deploy/argocd/apps/loxilb/config/dev.yaml
loxilb:
  bgp:
    enabled: true
    localASN: 65002
    # extBGPPeers: automatiquement remplacé par frr.ip:frr.asn en mode bgp
```

## Déploiement

### Différences vs Mode L2

| Aspect | Mode L2 | Mode BGP (FRR) |
|--------|---------|----------------|
| VIP annonce | GARP (L2 ARP) | BGP /32 routes |
| Cilium peer | loxilb direct | FRR router |
| Politique BGP host-ingress | `loxilb-bgp-host-ingress` | `frr-bgp-host-ingress` |
| VM Vagrant supplémentaire | Non | Oui (k8s-dev-frr1) |
| `--extBGPPeers` kube-loxilb | `master_ip:cilium_asn` | `frr_ip:frr_asn` |

### ApplicationSet

L'ApplicationSet FRR déploie **uniquement** des network policies (pas de pods) :

- `frr-bgp-host-ingress` — autorise TCP 179 depuis `frr.ip` vers tous les nodes

Ces policies ne sont déployées que si `features.loadBalancer.mode: bgp`.

## Infrastructure Vagrant

La VM FRR est créée automatiquement par le Vagrantfile :

```ruby
# Vagrantfile - VM FRR conditionnelle
if lb_provider == 'loxilb' && lb_mode == 'bgp'
  config.vm.define "k8s-#{$cluster_name}-frr" do |frr|
    frr.vm.network "private_network", ip: "#{$network_prefix}.45"
    # 1 vCPU, 512 MB RAM, 10 GB disk
    frr.vm.provision "shell", path: "../deploy/argocd/apps/frr/vagrant/provision-frr.sh"
  end
end
```

### Script de provisioning (`vagrant/provision-frr.sh`)

Le script :

1. Vérifie que `loadBalancer.mode: bgp` (sinon exit 0)
2. Lit les ASN depuis `config.yaml` et `apps/loxilb/config/{env}.yaml`
3. Installe FRR (`apt-get install frr`)
4. Active `bgpd=yes` dans `/etc/frr/daemons`
5. Génère `/etc/frr/frr.conf` avec les deux peers BGP
6. Configure sysctl persistants (`ip_forward=1`, `proxy_arp=1` sur eth1)
7. Redémarre FRR

## Rebuild requis

Le mode BGP change `bgpControlPlane.enabled` dans Cilium (Helm value au bootstrap). Un rebuild complet est nécessaire :

```bash
make vagrant-dev-destroy && make dev-full
```

## Vérification

```bash
# 1. Sessions BGP sur FRR
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show bgp summary"
# Attendu: 2 neighbors "Established"
#   192.168.121.40 (loxilb) + 192.168.121.50 (Cilium master)

# 2. Routes apprises par FRR
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show bgp ipv4 unicast"
# VIPs /32 via .40 (de loxilb) + PodCIDR 10.42.0.0/24 via .50 (de Cilium)

# 3. loxilb apprend PodCIDR via FRR
vagrant ssh k8s-dev-loxilb -- docker exec loxilb-external gobgp global rib
# 10.42.0.0/24 via 192.168.121.45 (FRR, pas .50 direct)

# 4. Proxy-ARP FRR pour les VIPs
ip neigh show 192.168.121.210  # Doit pointer vers MAC eth1 de la VM FRR

# 5. Sessions BGP loxilb <-> FRR
vagrant ssh k8s-dev-loxilb -- docker exec loxilb-external gobgp neighbor
# Attendu: 192.168.121.45 (FRR) Established

# 6. End-to-end
curl -sk https://argocd.k8s.lan | head -1  # HTTP 200
```

## Troubleshooting

### Session BGP ne s'établit pas

```bash
# Vérifier que FRR est en cours d'exécution
vagrant ssh k8s-dev-frr1 -- systemctl status frr

# Vérifier la config FRR
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show running-config"

# Vérifier la connectivité TCP 179 depuis loxilb vers FRR
vagrant ssh k8s-dev-loxilb -- nc -zv 192.168.121.45 179

# Vérifier les network policies (frr-bgp-host-ingress)
kubectl get ciliumclusterwidenetworkpolicy frr-bgp-host-ingress -o yaml
```

### Proxy-ARP non fonctionnel

```bash
# Vérifier sysctl sur la VM FRR
vagrant ssh k8s-dev-frr1 -- sysctl net.ipv4.conf.eth1.proxy_arp
# Attendu: 1

vagrant ssh k8s-dev-frr1 -- sysctl net.ipv4.ip_forward
# Attendu: 1
```

## Control Plane vs Data Plane

### Comportement en réseau flat L2 (lab)

En lab, toutes les VMs sont sur le même `/24` (`192.168.121.0/24`). Dans cette topologie :

- loxilb ajoute les VIPs sur son interface `lo` → répond directement à l'ARP
- Le trafic hôte → VIP va **directement** à loxilb (L2), **sans passer par FRR**
- FRR est uniquement dans le **control plane BGP** (échange de routes)

```
# Réseau flat L2 : FRR est HORS du data plane
Hôte (.1) ──ARP direct──→ loxilb (.40, VIP sur lo) ──DNAT──→ Pod
                           FRR (.45) : jamais traversé par les paquets
```

### Valeur de FRR même sans data plane

| Rôle | Impact |
|------|--------|
| BGP loxilb→FRR : loxilb apprend `10.42.0.0/24 via .50` | **Critical** : onearm SNAT a besoin des routes pods |
| BGP FRR→Cilium : Cilium apprend les VIPs /32 | **Critical** : retour de trafic pod→client |
| ECMP 3 paths vers VIP (MED=10/70/70) | **HA** : withdraw BGP en cas de panne loxilb |
| Redistribution de routes inter-AS | **Découplage** : loxilb et Cilium n'ont pas besoin de se connaître |

### Comportement en réseau segmenté (production)

En production avec des VLANs séparés (clients, infra, cluster), FRR est le **vrai routeur** entre les segments. Le trafic DOIT passer par FRR car les VIPs ne sont pas sur le même réseau L2 que les clients.

### VRRP Anycast Gateway

En lab flat L2, FRR n'est dans le data plane que si des routes statiques hôte pointent vers FRR. Avec 2 FRR et ECMP statique (`nexthop via .45 nexthop via .46`), si un FRR meurt, la moitié du trafic est perdu — les routes statiques n'ont aucun health-check.

**Solution** : VRRP anycast — les 2 FRR partagent un VIP unique (`.44`). L'hôte route via `.44`. Failover automatique en ~3s.

```
┌──────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Hôte    │     │  FRR1 (.45)      │     │  FRR2 (.46)      │
│          │     │  VRRP Master     │     │  VRRP Backup     │
│          │     │  priority 100    │     │  priority 50     │
│ route    │     │                  │     │                  │
│ via .44 ─┼────→│  VIP .44 (actif) │     │  VIP .44 (veille)│
│          │     └──────────────────┘     └──────────────────┘
└──────────┘            ↕ VRRP advertisements (proto 112)
```

#### Configuration

```yaml
# deploy/argocd/config/config.yaml
features:
  loadBalancer:
    bgp:
      vrrp:
        enabled: true
        vip: "192.168.121.44"       # VIP partagé (hors pools LB)
        vrid: 1                      # Virtual Router ID
        advertisementInterval: 100   # centisecondes (100 = 1s)
```

- Le VIP `.44` est choisi sous `.45` (FRR1), au-dessus de `.42` (loxilb3), hors des pools LB
- Le BGP peering reste sur les IPs réelles (`.45`/`.46`) — seul le data plane utilise le VIP
- La priorité est calculée automatiquement depuis l'index dans `bgp.peers[]` : index 0 = 100 (master), index 1 = 50 (backup)

#### Fonctionnement

Le script `provision-frr.sh` :

1. Active `vrrpd=yes` dans `/etc/frr/daemons`
2. Crée une interface macvlan `vrrp4-<ifindex>-<vrid>` sur eth1 avec le MAC virtuel VRRP (`00:00:5e:00:01:<vrid>`)
3. Ajoute la config VRRP à `/etc/frr/frr.conf` (VRRPv3, priority, advertisement-interval)
4. Active `arp_accept=1` sur eth1 pour le gratuitous ARP de failover
5. Persiste la macvlan via `networkd-dispatcher` pour les reboots

#### Routes hôte via VRRP VIP

```bash
# Route simple via VIP (failover automatique)
sudo ip route replace 192.168.121.210/32 via 192.168.121.44 dev virbr0
sudo ip route replace 192.168.121.201/32 via 192.168.121.44 dev virbr0

# Persistance
sudo nmcli connection modify virbr0 \
  +ipv4.routes "192.168.121.210/32 192.168.121.44, 192.168.121.201/32 192.168.121.44"
```

#### Vérification VRRP

```bash
# 1. Status VRRP
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show vrrp"
# VRID 1, priority 100, Status: Master
vagrant ssh k8s-dev-frr2 -- sudo vtysh -c "show vrrp"
# VRID 1, priority 50, Status: Backup

# 2. VIP ping
ping -c3 192.168.121.44

# 3. Test end-to-end via VIP
sudo ip route replace 192.168.121.210/32 via 192.168.121.44 dev virbr0
curl -sk https://argocd.k8s.lan --resolve argocd.k8s.lan:443:192.168.121.210 -w '%{http_code}\n'
# 200
```

#### Test failover VRRP (FRR)

```bash
# 1. Arrêter FRR1 (master)
vagrant halt k8s-dev-frr1
# Attendre ~3s pour le failover VRRP

# 2. Vérifier que FRR2 a pris le relais
vagrant ssh k8s-dev-frr2 -- sudo vtysh -c "show vrrp"
# Status: Master

# 3. Test end-to-end (toujours fonctionnel)
curl -sk https://argocd.k8s.lan --resolve argocd.k8s.lan:443:192.168.121.210 -w '%{http_code}\n'
# 200

# 4. Redémarrer FRR1 (preempt)
vagrant up k8s-dev-frr1
# Attendre ~10s
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show vrrp"
# Status: Master (preempt, priority 100 > 50)
```

#### Test failover loxilb HA

kube-loxilb gère le HA via MED BGP : MASTER annonce les VIPs avec MED=10, BACKUP avec MED=70. FRR sélectionne le plus bas MED.

```bash
# 1. Vérifier l'état HA (loxilb1=MASTER, loxilb2/3=BACKUP)
for vm in loxilb1 loxilb2 loxilb3; do
  vagrant ssh k8s-dev-$vm -- sudo docker exec loxilb-external loxicmd get ha
done

# 2. Arrêter le MASTER
virsh shutdown k8s-dev-loxilb1

# 3. Attendre ~15s pour convergence BGP + HA promotion
sleep 15

# 4. Vérifier promotion (un BACKUP devient MASTER)
vagrant ssh k8s-dev-frr1 -- sudo vtysh -c "show bgp ipv4 unicast 192.168.121.210/32"
# Best path: MED=10 via .41 ou .42 (nouveau MASTER)

# 5. Test end-to-end
for i in $(seq 1 10); do
  curl -sk --max-time 5 -o /dev/null -w "%{http_code} " \
    https://argocd.k8s.lan --resolve argocd.k8s.lan:443:192.168.121.210
done; echo
# 200 200 200 200 200 200 200 200 200 200

# 6. Recovery (pas de preemption — le nouveau MASTER reste)
virsh start k8s-dev-loxilb1
# loxilb1 revient en BACKUP, pas d'interruption
```

#### Contrainte BGP : holdTime > restartTime + keepaliveInterval

Quand un FRR tombe, GoBGP (Cilium) entre en graceful restart (GR) et **bloque le traitement des keepalives pour TOUS les peers** pendant `restartTimeSeconds`. Le hold timer compte depuis le **dernier keepalive traité** (pas depuis le début du GR). Formule :

```
holdTime > restartTime + keepaliveInterval
```

Avec `restartTime=120` et `keepalive=60` → `holdTime > 180`. On utilise `holdTime=300` (marge de 120s).

**Symptôme** : après shutdown de FRR1, Cilium perd AUSSI la session BGP vers FRR2. Le trafic HTTPS est interrompu ~7 min (reconvergence BGP + entrées conntrack stale dans loxilb).

**Fix Cilium** : dans `CiliumBGPPeerConfig` (`apps/loxilb/kustomize/cilium-bgp-peering/ciliumbgppeerconfig.yaml`) :

```yaml
timers:
  holdTimeSeconds: 300        # > restartTime (120) + keepalive (60) + marge
  keepAliveTimeSeconds: 60
  connectRetryTimeSeconds: 30 # reconnexion rapide après perte de session
gracefulRestart:
  enabled: true
  restartTimeSeconds: 120     # durée du GR
```

**Fix FRR** : dans `provision-frr.sh`, le peer Cilium a `neighbor <ip> timers 60 300` car BGP négocie le **minimum** des deux hold times. Sans ce timer côté FRR (default hold=180), le hold négocié serait `min(300, 180) = 180` — insuffisant.

#### Contrainte bridge : flood off sur les ports loxilb

Quand un FRR est arrêté (VM shutdown), ses ports bridge sont supprimés et son MAC disparaît de la FDB. Les instances loxilb tentent de reconnecter BGP (SYN TCP 179 vers le FRR mort). Ces SYNs ont comme MAC destination celui du FRR disparu → **unknown unicast** → le bridge les flood vers TOUS les ports, y compris les autres loxilb.

L'eBPF de chaque loxilb a une route et un voisin pour le FRR mort. Il re-forwarde les SYNs reçus vers eth1 → retour au bridge → re-flood → **boucle de feedback à 80-100k+ pps**. Cette avalanche sature les TAP queues et provoque ~80% de perte de paquets sur tous les ports bridge.

**Fix** : désactiver le flooding unknown-unicast sur les ports bridge des loxilb :

```bash
# Pour chaque VM loxilb
sudo bridge link set dev <vnetX> flood off
```

Le trafic légitime (unicast avec MAC destination connu, broadcast ARP, multicast) n'est pas affecté. Seuls les paquets unknown-unicast sont filtrés.

Ce fix est appliqué automatiquement via un Vagrant trigger (`vagrant/scripts/configure-loxilb-bridge-ports.sh`) après chaque `vagrant up` ou `vagrant reload` des VMs loxilb.

**Résultat** : HTTPS via VIP 10/10 (100%) même avec un FRR complètement arrêté.

#### Contrainte onearm : route retour via eth1

En mode onearm, loxilb envoie le retour (SYN-ACK) au MAC source du paquet entrant. Quand le trafic passe par FRR, le retour va vers FRR. FRR doit alors router le paquet vers l'hôte gateway (`.1`).

**Problème** : FRR a une route DHCP `192.168.121.1 dev eth0` (Vagrant management). Le retour sort par eth0 au lieu de eth1 (data plane) → le paquet n'atteint jamais le bridge → timeout.

**Fix** : `ip route replace 192.168.121.1/32 dev eth1` sur chaque FRR. Ce fix est appliqué automatiquement par `provision-frr.sh` (section "Route fix") et persisté via `networkd-dispatcher`.

### Forcer FRR dans le data plane (lab)

Pour simuler une topologie production en lab, ajouter des routes statiques sur l'hôte pour les VIPs via FRR.

**Avec VRRP (recommandé)** — route unique via le VIP partagé, failover automatique :

```bash
sudo ip route replace 192.168.121.210/32 via 192.168.121.44 dev virbr0
sudo ip route replace 192.168.121.201/32 via 192.168.121.44 dev virbr0
```

**Sans VRRP (legacy)** — ECMP statique, pas de failover :

```bash
# Routes ECMP via FRR1 + FRR2 (multi-path)
sudo ip route replace 192.168.121.210/32 \
  nexthop via 192.168.121.45 dev virbr0 weight 1 \
  nexthop via 192.168.121.46 dev virbr0 weight 1

sudo ip route replace 192.168.121.201/32 \
  nexthop via 192.168.121.45 dev virbr0 weight 1 \
  nexthop via 192.168.121.46 dev virbr0 weight 1
```

**Hash ECMP L4** (requis pour ECMP sans VRRP avec même src/dst IP) :

```bash
sudo sysctl -w net.ipv4.fib_multipath_hash_policy=1
```

### Vérification du data plane via FRR

```bash
# Vérifier que les routes passent par FRR
ip route get 192.168.121.210
# Avec VRRP: 192.168.121.210 via 192.168.121.44 dev virbr0
# Sans VRRP: 192.168.121.210 via 192.168.121.45 dev virbr0

# Tracepath pour confirmer le hop intermédiaire
tracepath -n 192.168.121.210

# Test end-to-end via FRR
curl -sk https://argocd.k8s.lan --resolve argocd.k8s.lan:443:192.168.121.210 -o /dev/null -w '%{http_code}\n'
# Attendu: 200
```

> **Note** : ces routes hôte sont éphémères (perdues au reboot). Pour les rendre persistantes :
> ```bash
> # Avec VRRP
> sudo nmcli connection modify virbr0 \
>   +ipv4.routes "192.168.121.210/32 192.168.121.44, 192.168.121.201/32 192.168.121.44"
> # Sans VRRP (single FRR)
> sudo nmcli connection modify virbr0 \
>   +ipv4.routes "192.168.121.210/32 192.168.121.45, 192.168.121.201/32 192.168.121.45"
> ```

#### Contrainte ECMP : hash L4 sur FRR (fib_multipath_hash_policy=1)

FRR reçoit les VIP `/32` via BGP depuis N instances loxilb → routes ECMP multipath. Par défaut, Linux utilise un hash **L3-only** (`hash_policy=0`) : seuls src IP + dst IP déterminent le nexthop.

**Problème** : tout le trafic d'un même client vers une même VIP (même src/dst IP) est envoyé au MÊME loxilb. Si ce loxilb est indisponible (eBPF bug post-restart, crash), 100% du trafic client est perdu — pas 1/N.

**Fix** : `fib_multipath_hash_policy=1` → hash L3+L4 (inclut les ports src/dst). Chaque connexion (port src différent) est distribuée indépendamment sur les N nexthops. Impact d'un loxilb défaillant limité à ~1/N.

```bash
# Vérifier
sysctl net.ipv4.fib_multipath_hash_policy
# Attendu: 1
```

Ce sysctl est appliqué automatiquement par `provision-frr.sh` via `/etc/sysctl.d/99-frr-routing.conf`.

## Références

- [FRR Documentation](https://docs.frrouting.org/)
- [FRR GitHub](https://github.com/FRRouting/frr)
- [BGP dans Cilium](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
- [LoxiLB BGP](https://docs.loxilb.io/)
