# FRR — Routeur BGP Upstream

FRR (Free Range Routing) est un routeur BGP open-source qui simule un **routeur physique upstream** en mode BGP pur (`loadBalancer.mode: bgp`). Il est déployé comme VM Vagrant dédiée (`k8s-<cluster>-frr`) pour éliminer les GARP et remplacer les annonces L2 par du routage BGP pur.

## Rôle

FRR est **générique** — il n'est pas spécifique à LoxiLB. Son rôle est de peer avec tous les composants BGP du cluster :

- **LoxiLB** (ASN 65002) → FRR apprend les VIP `/32` routes
- **Cilium** (ASN 64512) → FRR apprend les PodCIDR routes
- **Proxy-ARP sur eth1** → FRR répond aux ARP de l'hôte pour les VIPs → forward vers loxilb

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

## Références

- [FRR Documentation](https://docs.frrouting.org/)
- [FRR GitHub](https://github.com/FRRouting/frr)
- [BGP dans Cilium](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
- [LoxiLB BGP](https://docs.loxilb.io/)
