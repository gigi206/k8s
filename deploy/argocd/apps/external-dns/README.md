# External-DNS - Automatic DNS Management

External-DNS synchronise automatiquement les ressources Kubernetes (Ingress, Service, etc.) avec un provider DNS.

## Architecture

External-DNS supporte **deux modes** de fonctionnement:

### Mode 1: External Provider (Cloudflare, AWS, Google, etc.)

Synchronise avec un provider DNS externe (cloudflare, aws-route53, google-clouddns, azure-dns, etc.).

**Architecture:**
```
Kubernetes Resources → External-DNS → Provider API → DNS Records
(Ingress/Service)                     (Cloudflare)
```

**Avantages:**
- DNS accessible depuis Internet
- Gestion centralisée des domaines publics
- Support de nombreux providers (50+)

**Inconvénients:**
- Nécessite credentials pour le provider
- DNS public uniquement
- Rate limiting possible

### Mode 2: CoreDNS Local (avec etcd backend)

Déploie un serveur DNS local (CoreDNS) avec etcd comme backend de stockage.

**Architecture:**
```
Kubernetes Resources → External-DNS → etcd → CoreDNS → Clients DNS
(Ingress/Service)                   (backend) (server)  (port 53)
```

**Avantages:**
- DNS privé, pas besoin de provider externe
- Aucune limite de rate
- Idéal pour développement/testing
- Pas de credentials nécessaires

**Inconvénients:**
- DNS local uniquement (non accessible depuis Internet)
- Nécessite plus de resources (CoreDNS + etcd)
- Clients doivent pointer vers l'IP du service CoreDNS

## Configuration

### Mode External Provider

**Dev (config-dev.yaml)** - exemple Cloudflare:
```yaml
externalDns:
  provider: "cloudflare"  # ou aws, google, azure, etc.
  domainFilters:
   - "example.com"
  txtOwnerId: "external-dns-dev"
  sources:
   - "service"
   - "ingress"
   - "crd"
  interval: "15s"
  policy: "sync"
```

**Providers supportés:**
- `cloudflare`: Cloudflare DNS
- `aws`: AWS Route53
- `google`: Google Cloud DNS
- `azure`: Azure DNS
- `digitalocean`: DigitalOcean DNS
- `linode`: Linode DNS
- `ovh`: OVH DNS
- etc. (50+ providers)

### Mode CoreDNS Local

**Dev (config-dev.yaml)** - DNS local:
```yaml
externalDns:
  provider: "coredns"
  domainFilters:
   - "k8s.lan"  # Votre domaine local
  txtOwnerId: "external-dns-dev"
  sources:
   - "service"
   - "ingress"
   - "crd"
  interval: "15s"
  policy: "sync"

  # CoreDNS configuration
  coredns:
    enabled: true
    replicas: 1
    serviceType: "LoadBalancer"
    # Optional: IP fixe pour MetalLB
    # loadBalancerIP: "192.168.1.53"

  # etcd configuration
  etcd:
    enabled: true
    replicas: 1
```

## Utilisation

### Avec Ingress

External-DNS détecte automatiquement les Ingress et crée les enregistrements DNS:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: default
spec:
  ingressClassName: nginx
  rules:
 - host: app.example.com  # DNS créé automatiquement
    http:
      paths:
     - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 80
```

External-DNS créera un enregistrement DNS `app.example.com` pointant vers l'IP du LoadBalancer ingress-nginx.

### Avec Service LoadBalancer

External-DNS peut aussi créer des DNS pour les Services avec annotation:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: service.example.com
spec:
  type: LoadBalancer
  ports:
 - port: 80
    targetPort: 8080
  selector:
    app: my-app
```

External-DNS créera un enregistrement DNS `service.example.com` pointant vers l'IP du LoadBalancer.

### Avec DNSEndpoint CRD

Pour un contrôle plus fin, utilisez la CRD DNSEndpoint:

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: custom-dns
  namespace: default
spec:
  endpoints:
 - dnsName: custom.example.com
    recordType: A
    targets:
   - 192.168.1.100
 - dnsName: alias.example.com
    recordType: CNAME
    targets:
   - custom.example.com
```

## Configuration des Clients DNS (Mode CoreDNS)

Quand vous utilisez le mode CoreDNS local, les clients doivent pointer vers l'IP du service CoreDNS.

### Option 1: Via /etc/resolv.conf

Sur Linux, ajouter CoreDNS comme resolver:

```bash
# Récupérer l'IP du service CoreDNS
COREDNS_IP=$(kubectl get svc -n external-dns coredns-coredns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Ajouter au resolv.conf
echo "nameserver $COREDNS_IP" | sudo tee -a /etc/resolv.conf
```

### Option 2: Via systemd-resolved

```bash
# Configurer pour le domaine spécifique
sudo resolvectl dns eth0 $COREDNS_IP
sudo resolvectl domain eth0 ~k8s.lan
```

### Option 3: Via dnsmasq

```bash
# Ajouter dans /etc/dnsmasq.conf
server=/k8s.lan/$COREDNS_IP
```

### Option 4: Via NetworkManager

```bash
# Fichier /etc/NetworkManager/dnsmasq.d/external-dns.conf
server=/k8s.lan/$COREDNS_IP
```

## Vérification

### Vérifier le déploiement

```bash
# Pods external-dns
kubectl get pods -n external-dns

# Si mode CoreDNS: vérifier CoreDNS et etcd
kubectl get pods -n external-dns | grep coredns
kubectl get pods -n external-dns | grep etcd

# Service CoreDNS (mode CoreDNS uniquement)
kubectl get svc -n external-dns

# DNSEndpoint CRDs créés
kubectl get dnsendpoint --all-namespaces
```

### Tester la résolution DNS

**Mode External Provider:**
```bash
# Attendre quelques secondes pour la propagation
sleep 30

# Tester la résolution
nslookup app.example.com

# Vérifier l'IP retournée
dig app.example.com +short
```

**Mode CoreDNS:**
```bash
# Récupérer l'IP CoreDNS
COREDNS_IP=$(kubectl get svc -n external-dns coredns-coredns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Tester directement contre CoreDNS
nslookup app.k8s.lan $COREDNS_IP
dig @$COREDNS_IP app.k8s.lan +short

# Vérifier les enregistrements dans etcd
kubectl exec -n external-dns deployment/external-dns-etcd -- \
  etcdctl get --prefix /skydns
```

### Logs

```bash
# Logs external-dns
kubectl logs -n external-dns deployment/external-dns -f

# Logs CoreDNS (mode CoreDNS uniquement)
kubectl logs -n external-dns deployment/coredns-coredns -f

# Logs etcd (mode CoreDNS uniquement)
kubectl logs -n external-dns deployment/external-dns-etcd -f
```

## Troubleshooting

### DNS pas créé (External Provider)

**Problème**: Les enregistrements DNS ne sont pas créés

**Vérifications:**
```bash
# Logs external-dns
kubectl logs -n external-dns deployment/external-dns

# Provider credentials configurées ?
kubectl get secret -n external-dns

# domainFilters correctement configuré ?
# Vérifier dans config-dev.yaml ou config-prod.yaml

# Ingress/Service a le bon hostname ?
kubectl describe ingress my-app
```

**Causes courantes:**
- Credentials manquantes ou invalides
- Domain filter ne match pas le hostname
- Provider rate limiting
- Permissions insuffisantes

### DNS pas créé (Mode CoreDNS)

**Problème**: Les enregistrements DNS ne sont pas créés dans CoreDNS

**Vérifications:**
```bash
# etcd fonctionne ?
kubectl get pods -n external-dns -l app=external-dns-etcd

# External-DNS connecté à etcd ?
kubectl logs -n external-dns deployment/external-dns | grep etcd

# Enregistrements dans etcd ?
kubectl exec -n external-dns deployment/external-dns-etcd -- \
  etcdctl get --prefix /skydns

# CoreDNS connecté à etcd ?
kubectl logs -n external-dns deployment/coredns-coredns | grep etcd
```

### Résolution DNS échoue (Mode CoreDNS)

**Problème**: `nslookup app.k8s.lan` échoue

**Vérifications:**
```bash
# Service CoreDNS a une IP externe ?
kubectl get svc -n external-dns coredns-coredns

# MetalLB fonctionne ?
kubectl get pods -n metallb-system

# Client DNS pointe vers CoreDNS ?
cat /etc/resolv.conf | grep nameserver

# Tester directement CoreDNS
COREDNS_IP=$(kubectl get svc -n external-dns coredns-coredns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
nslookup app.k8s.lan $COREDNS_IP
```

### Conflit d'ownership

**Problème**: `TXT record "heritage=external-dns,..." conflict`

**Solution:**
```yaml
# Utiliser un txtOwnerId unique par environnement
externalDns:
  txtOwnerId: "external-dns-dev"  # Dev
  # txtOwnerId: "external-dns-prod"  # Prod
```

### Policy: sync vs upsert-only

**Différences:**
- `sync`: External-DNS crée ET supprime les enregistrements (recommandé)
- `upsert-only`: External-DNS crée mais ne supprime JAMAIS

```yaml
externalDns:
  policy: "sync"  # ou "upsert-only"
```

## Configuration Avancée

### Sources multiples

```yaml
externalDns:
  sources:
   - "service"         # Services LoadBalancer
   - "ingress"         # Ingress resources
   - "crd"             # DNSEndpoint CRDs
   - "istio-gateway"   # Istio Gateway
   - "istio-virtualservice"  # Istio VirtualService
```

### Filtres de domaine

```yaml
externalDns:
  domainFilters:
   - "example.com"     # Seulement example.com
   - "*.example.com"   # Tous les sous-domaines
   - "test.local"      # Domaine local
```

### Annotations Ingress

```yaml
metadata:
  annotations:
    # Forcer un hostname spécifique
    external-dns.alpha.kubernetes.io/hostname: custom.example.com

    # TTL personnalisé
    external-dns.alpha.kubernetes.io/ttl: "60"

    # Target personnalisé (IP ou CNAME)
    external-dns.alpha.kubernetes.io/target: "192.168.1.100"
```

### Credentials Provider (Cloudflare exemple)

```bash
# Créer un secret avec le token API
kubectl create secret generic cloudflare-api-token \
  --from-literal=token=YOUR_CLOUDFLARE_API_TOKEN \
  -n external-dns

# Ajouter dans l'ApplicationSet
- name: env[0].name
  value: "CF_API_TOKEN"
- name: env[0].valueFrom.secretKeyRef.name
  value: "cloudflare-api-token"
- name: env[0].valueFrom.secretKeyRef.key
  value: "token"
```

## Exemples

### App complète avec DNS automatique (Mode CoreDNS)

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: default
spec:
  ports:
 - port: 80
    targetPort: 8080
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
     - name: httpbin
        image: kennethreitz/httpbin
        ports:
       - containerPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpbin
  namespace: default
spec:
  ingressClassName: nginx
  rules:
 - host: httpbin.k8s.lan  # DNS créé automatiquement
    http:
      paths:
     - path: /
        pathType: Prefix
        backend:
          service:
            name: httpbin
            port:
              number: 80
```

Après déploiement:
```bash
# Attendre que external-dns crée le DNS (15s par défaut)
sleep 20

# Tester (avec DNS client configuré)
curl http://httpbin.k8s.lan/get
```

## Docs

- [External-DNS Documentation](https://github.com/kubernetes-sigs/external-dns)
- [Supported Providers](https://github.com/kubernetes-sigs/external-dns#status-of-providers)
- [CoreDNS Documentation](https://coredns.io/manual/toc/)
- [etcd Documentation](https://etcd.io/docs/)
