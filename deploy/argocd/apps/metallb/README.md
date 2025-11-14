# MetalLB - LoadBalancer for Bare-Metal Kubernetes

MetalLB est une implémentation de LoadBalancer pour les clusters Kubernetes bare-metal. Il fournit des adresses IP externes pour les Services de type `LoadBalancer`.

## Vue d'Ensemble

**Deployment**: Helm chart + ressources Git (IPAddressPool, L2Advertisement)
**Wave**: 10 (déployé tôt, avant ingress et autres apps)
**Chart**: [metallb/metallb](https://github.com/metallb/metallb)
**Namespace**: `metallb-system`

## Dépendances

### Requises
- **Kubernetes 1.13+**
- **kube-proxy**: Mode IPVS ou iptables (IPVS recommandé pour performance)
- **Plage d'IPs disponibles**: IPs non utilisées sur le réseau local

### Optionnelles
- **Prometheus Stack** (Wave 70): Pour monitoring des speakers et controller
- **BGP Router** (mode BGP uniquement): Pour advertisement BGP

## Architecture

MetalLB fonctionne en **deux modes** principaux:

### Mode 1: Layer 2 (ARP/NDP)

**Principe**:
- Un speaker MetalLB élu répond aux requêtes ARP pour les IPs LoadBalancer
- Le trafic arrive directement sur le node du speaker élu
- Failover automatique si le speaker principal tombe

**Architecture**:
```
Client → ARP request (who has 192.168.1.240?)
      → MetalLB Speaker (I have it!)
      → Traffic to Node
      → kube-proxy → Service → Pods
```

**Avantages**:
- Simple à configurer (pas de routeur BGP requis)
- Fonctionne sur n'importe quel réseau L2
- Pas de configuration réseau externe

**Inconvénients**:
- Single-node failover (un seul speaker actif par IP)
- Pas de load-balancing (tout le trafic passe par un node)
- Ne fonctionne que sur le réseau local (L2)

### Mode 2: BGP

**Principe**:
- MetalLB speakers annoncent les IPs LoadBalancer via BGP
- Le routeur BGP distribue le trafic entre les nodes
- Load-balancing ECMP (Equal-Cost Multi-Path) possible

**Architecture**:
```
Client → Router BGP → ECMP between nodes
                   → MetalLB Speakers (multiple)
                   → kube-proxy → Service → Pods
```

**Avantages**:
- True load-balancing (ECMP)
- Failover rapide via BGP
- Fonctionne sur plusieurs datacenters

**Inconvénients**:
- Nécessite un routeur BGP
- Configuration réseau plus complexe
- Requiert AS numbers et peering BGP

## Configuration

Cette infrastructure utilise le **Mode L2** (Layer 2) par défaut.

### Dev (config-dev.yaml)

```yaml
metallb:
  ipAddressPool:
    - name: default
      addresses:
        - 192.168.1.220-192.168.1.250  # 31 IPs disponibles
```

**IPAddressPool** (ressource déployée via Git):
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.220-192.168.1.250
```

**L2Advertisement** (ressource déployée via Git):
```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
spec:
  ipAddressPools:
    - default
```

### Prod (config-prod.yaml)

```yaml
metallb:
  ipAddressPool:
    - name: default
      addresses:
        - 192.168.1.240-192.168.1.250  # 11 IPs (production réservée)
```

**Différences dev/prod**:
- **Dev**: Range 192.168.1.220-250 (31 IPs pour testing)
- **Prod**: Range 192.168.1.240-250 (11 IPs réservées production)

**Note**: Assurez-vous que ces IPs ne sont **pas utilisées** par DHCP ou d'autres devices.

## Usage

### Service LoadBalancer Basic

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: default
spec:
  type: LoadBalancer  # MetalLB assignera une IP
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

**Vérifier l'IP assignée**:
```bash
kubectl get svc my-service
# NAME         TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
# my-service   LoadBalancer   10.43.100.123   192.168.1.220    80:30123/TCP

# Tester l'accès
curl http://192.168.1.220
```

### Service avec IP Spécifique

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.1.225  # IP spécifique du pool
  ports:
  - port: 80
    targetPort: 8080
```

**Note**: L'IP doit être dans le range de l'IPAddressPool.

### Service avec Pool Spécifique

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    metallb.universe.tf/address-pool: default  # Pool name
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
```

### Sharing IP (Multiple Services)

```yaml
# Service 1: HTTP
apiVersion: v1
kind: Service
metadata:
  name: my-service-http
  annotations:
    metallb.universe.tf/allow-shared-ip: "my-shared-ip"
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.1.230
  ports:
  - port: 80
    targetPort: 8080

---
# Service 2: HTTPS (même IP)
apiVersion: v1
kind: Service
metadata:
  name: my-service-https
  annotations:
    metallb.universe.tf/allow-shared-ip: "my-shared-ip"
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.1.230
  ports:
  - port: 443
    targetPort: 8443
```

**Note**: Les ports doivent être différents.

## Monitoring

### Prometheus Metrics

**ServiceMonitors** (déployés via `prometheus.yaml`):
- `metallb-speaker`: Metrics des speaker pods (port 7472)
- `metallb-controller`: Metrics du controller (port 7472)

**Métriques clés**:
```promql
# IP allocation
metallb_allocator_addresses_in_use_total   # IPs utilisées
metallb_allocator_addresses_total          # IPs totales

# BGP (mode BGP uniquement)
metallb_bgp_session_up                     # Sessions BGP actives
metallb_bgp_updates_total                  # Updates BGP

# L2 announcements
metallb_speaker_announced                  # IPs annoncées en L2

# Configuration
metallb_k8s_client_config_loaded_bool      # Config chargée
metallb_k8s_client_updates_total           # Updates config
```

### PrometheusRule Alerts

**8 alertes configurées** (`prometheus.yaml`):

**Critiques**:
- `MetalLBControllerDown`: Controller down (5m)
- `MetalLBAllSpeakersDown`: Tous les speakers down (5m)
- `MetalLBIPPoolFull`: Pool IP complètement plein (1m)
- `MetalLBMetricsMissing`: Pas de métriques (10m)

**Warnings**:
- `MetalLBSpeakerDown`: Un speaker down sur un node (2m)
- `MetalLBIPPoolExhausted`: Pool IP >90% plein (5m)
- `MetalLBBGPSessionDown`: Session BGP down (2m, mode BGP uniquement)
- `MetalLBStaleConfig`: Config pas appliquée (10m)

## Troubleshooting

### Service reste en "Pending"

**Symptôme**: `EXTERNAL-IP` reste `<pending>`

**Vérifications**:
```bash
# Voir le service
kubectl get svc my-service
kubectl describe svc my-service

# Events
kubectl get events -n metallb-system

# Pods MetalLB
kubectl get pods -n metallb-system

# Logs controller
kubectl logs -n metallb-system deployment/metallb-controller

# Logs speaker
kubectl logs -n metallb-system daemonset/metallb-speaker
```

**Causes courantes**:
- **IPAddressPool vide**: Aucun IP disponible
- **Pool épuisé**: Toutes les IPs utilisées
- **Configuration invalide**: IPAddressPool ou L2Advertisement mal configuré
- **MetalLB pods down**: Controller ou speakers crashés

**Solutions**:
```bash
# Vérifier les IPAddressPools
kubectl get ipaddresspool -n metallb-system

# Vérifier les L2Advertisements
kubectl get l2advertisement -n metallb-system

# Vérifier les IPs allouées
kubectl get svc --all-namespaces -o wide | grep LoadBalancer
```

### IP non accessible

**Symptôme**: IP assignée mais pas de réponse réseau

**Vérifications**:
```bash
# Ping l'IP
ping 192.168.1.220

# ARP cache
arp -a | grep 192.168.1.220

# Vérifier le speaker qui annonce
kubectl logs -n metallb-system daemonset/metallb-speaker | grep 192.168.1.220

# Vérifier kube-proxy
kubectl get svc my-service
kubectl get endpoints my-service
```

**Causes courantes**:
- **IP en dehors du subnet**: L'IP n'est pas routable depuis votre client
- **Firewall**: Firewall bloque le trafic
- **Node network**: Le node speaker n'a pas de connectivité réseau
- **Speaker pas sur le bon node**: Speaker élu est sur un node isolé

**Solutions**:
- Vérifier que l'IP est dans le même subnet que votre client
- Désactiver le firewall temporairement pour tester
- Vérifier la connectivité réseau des nodes

### IP pool exhausted

**Symptôme**: Alerte `MetalLBIPPoolExhausted`

**Vérifier l'utilisation**:
```bash
# Compter les services LoadBalancer
kubectl get svc --all-namespaces | grep LoadBalancer | wc -l

# Lister toutes les IPs utilisées
kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}'
```

**Solutions**:
- **Augmenter le range**: Modifier IPAddressPool
- **Libérer des IPs**: Supprimer les services non utilisés
- **Partager des IPs**: Utiliser `metallb.universe.tf/allow-shared-ip`

### Speaker crashloop

**Symptôme**: Speaker pods en CrashLoopBackOff

**Vérifications**:
```bash
# Logs speaker
kubectl logs -n metallb-system daemonset/metallb-speaker

# Describe pod
kubectl describe pod -n metallb-system -l app.kubernetes.io/component=speaker
```

**Causes courantes**:
- **FRR disabled**: `speaker.frr.enabled: false` (notre config)
- **Permission denied**: RBAC ou SecurityContext
- **Network plugin conflict**: Conflit avec CNI (Calico, Cilium)

## Configuration Avancée

### Mode BGP

**Configuration BGP** (à ajouter):
```yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: router-bgp
  namespace: metallb-system
spec:
  myASN: 64500
  peerASN: 64501
  peerAddress: 192.168.1.1

---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-advert
  namespace: metallb-system
spec:
  ipAddressPools:
    - default
```

### Multiple IP Pools

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.245
  autoAssign: false  # Assignation manuelle

---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: development
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.220-192.168.1.230
  autoAssign: true
```

**Usage**:
```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    metallb.universe.tf/address-pool: production
spec:
  type: LoadBalancer
```

## Docs

- [MetalLB Documentation](https://metallb.universe.tf/)
- [L2 Configuration](https://metallb.universe.tf/configuration/_advanced_l2_configuration/)
- [BGP Configuration](https://metallb.universe.tf/configuration/_advanced_bgp_configuration/)
- [Usage Guide](https://metallb.universe.tf/usage/)
- [Troubleshooting](https://metallb.universe.tf/troubleshooting/)
