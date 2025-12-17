# Ingress-NGINX - Ingress Controller

Ingress-NGINX est un contrôleur d'entrée Kubernetes qui gère le routage HTTP/HTTPS vers les services.

## Dépendances

### Automatiques (via ApplicationSets)
Ces composants sont déployés automatiquement dans le bon ordre grâce aux sync waves:

- **MetalLB** (Wave 10): Fournit les IPs LoadBalancer pour le service ingress-nginx
- **Cert-Manager** (Wave 20): Génère automatiquement les certificats TLS
- **Prometheus Stack** (Wave 75): Pour le monitoring ingress-nginx
  - ServiceMonitor et PrometheusRule déployés si `features.monitoring.enabled: true`
  - 5 alertes automatiques (config failed, certificate expiry, 4XX/5XX errors, metrics missing)

### Manuelles

Aucune dépendance manuelle.

## Configuration

### Environnements

**Dev (`config-dev.yaml`):**
- Controller kind: Deployment (1 replica)
- Default IngressClass: true
- Resources minimales (100m CPU, 128Mi memory)
- Default backend: enabled (1 replica)
- Admission webhooks: minimal resources
- Auto-sync: enabled

**Prod (`config-prod.yaml`):**
- Controller kind: Deployment (3 replicas pour HA)
- Default IngressClass: true
- Resources plus élevées (200-1000m CPU, 256-512Mi memory)
- Default backend: enabled (2 replicas)
- Admission webhooks: higher resources
- Auto-sync: disabled (manual)

### Controller Kind

Le controller peut être déployé en mode **Deployment** ou **DaemonSet**:

**Deployment (par défaut):**
- Nombre de replicas configurable
- Load balancing via MetalLB/Kube-VIP
- Idéal pour la plupart des clusters

**DaemonSet:**
- Un pod par node
- Utilise hostNetwork pour accès direct
- Idéal pour bare-metal avec accès direct aux ports 80/443

Configuration:
```yaml
# Dans config-dev.yaml ou config-prod.yaml
ingressNginx:
  controller:
    kind: "Deployment"  # ou "DaemonSet"
```

### Admission Webhooks

Les **admission webhooks** d'ingress-nginx valident la configuration des Ingress avant leur création dans le cluster.

**Problème avec ArgoCD**:
ArgoCD ne supporte pas les **Helm hooks** (jobs `pre-install`, `post-install`) qui créent et patchent normalement les certificats TLS du webhook. Sans ces jobs:
- Le webhook n'a pas de certificat TLS valide
- Les Ingress ne peuvent pas être validés
- Erreur: `x509: certificate signed by unknown authority`

**Solution: Intégration cert-manager**:
Au lieu d'utiliser les Helm hooks, on configure ingress-nginx pour utiliser cert-manager qui gère automatiquement:

1. **Certificate** auto-signé pour le webhook
2. **Issuer** pour générer les certificats
3. **cert-manager-cainjector** injecte automatiquement le CA bundle dans le `ValidatingWebhookConfiguration`

Configuration activée dans `applicationset.yaml`:
```yaml
- name: controller.admissionWebhooks.enabled
  value: "true"
- name: controller.admissionWebhooks.certManager.enabled
  value: "true"                              # ✅ Utilise cert-manager
- name: controller.admissionWebhooks.patch.enabled
  value: "false"                             # ❌ Désactive les Helm hooks
```

**Vérification**:
```bash
# Certificats créés par cert-manager
kubectl get certificate -n ingress-nginx
# NAME                      READY   SECRET                    AGE
# ingress-nginx-admission   True    ingress-nginx-admission   5m
# ingress-nginx-root-cert   True    ingress-nginx-root-cert   5m

# Webhook configuré avec CA bundle
kubectl get validatingwebhookconfiguration ingress-nginx-admission \
  -o jsonpath='{.metadata.annotations.cert-manager\.io/inject-ca-from}'
# ingress-nginx/ingress-nginx-admission

# Pas d'erreurs TLS dans les logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller | grep "TLS handshake error"
```

**Avantages**:
- ✅ Compatible ArgoCD (pas de Helm hooks)
- ✅ Rotation automatique des certificats
- ✅ Cohérent avec le reste de l'infrastructure (cert-manager)
- ✅ GitOps-friendly

### Configuration Options

**Proxy Body Size:**
Taille maximale des requêtes HTTP (par défaut: 100m):
```yaml
ingressNginx:
  controller:
    config:
      proxy-body-size: "100m"  # ou "500m", "1g", etc.
```

**Service Type:**
```yaml
ingressNginx:
  controller:
    service:
      type: "LoadBalancer"  # ou "NodePort", "ClusterIP"
```

## Utilisation

### Ingress de base

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: default
spec:
  ingressClassName: nginx  # Utilise ingress-nginx
  rules:
  - host: app.example.com
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

### Ingress avec TLS (cert-manager)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-tls
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    secretName: app-tls
  rules:
  - host: app.example.com
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

### Annotations Avancées

#### Rate Limiting

Limiter le nombre de requêtes par seconde/minute:
```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/limit-rps: "10"        # 10 req/sec
    nginx.ingress.kubernetes.io/limit-rpm: "600"       # 600 req/min
    nginx.ingress.kubernetes.io/limit-connections: "5"  # 5 connexions concurrentes
```

#### SSL/TLS

```yaml
metadata:
  annotations:
    # Redirection HTTPS forcée
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

    # SSL Passthrough (pour terminer TLS au backend)
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"

    # Backend Protocol
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"  # ou HTTP, GRPC, GRPCS, AJP, FCGI
```

#### Timeouts

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
```

#### Body Size

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"  # Taille max requête
```

#### CORS

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://example.com"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
```

#### IP Whitelisting

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,192.168.0.0/16"
```

#### Session Affinity (Sticky Sessions)

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "route"
    nginx.ingress.kubernetes.io/session-cookie-expires: "172800"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "172800"
```

#### Rewrite URL

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: Prefix
```

## Monitoring

### Prometheus

Si `features.monitoring.enabled: true`, les ressources suivantes sont déployées:

**ServiceMonitor:**
- Collecte les métriques ingress-nginx depuis le controller

**PrometheusRule (5 Alertes):**

1. **NGINXConfigFailed** (critical, 1s):
   - Échec du reload de config nginx
   - Action: Désinstaller les derniers changements d'ingress

2. **NGINXCertificateExpiry** (critical, 1s):
   - Certificat SSL expire dans moins de 7 jours
   - Action: Renouveler les certificats

3. **NGINXTooMany500s** (warning, 1m):
   - Plus de 5% de requêtes retournent 5XX
   - Action: Vérifier les backends

4. **NGINXTooMany4XXs** (warning, 1m):
   - Plus de 5% de requêtes retournent 4XX
   - Action: Vérifier la configuration et les requêtes

5. **NGINXMetricsMissing** (critical, 15m):
   - Aucune métrique reportée depuis 15 minutes
   - Action: Vérifier que nginx est up

### Grafana Dashboard

Dashboard officiel ingress-nginx disponible:
- **ID Grafana**: 9614 (NGINX Ingress controller)
- Dashboard URL: https://grafana.com/grafana/dashboards/9614

Installation:
1. Accéder à Grafana (`grafana.{{ .common.domain }}`)
2. Import Dashboard → ID **9614**
3. Sélectionner Prometheus comme datasource

## Vérification

### Vérifier le déploiement

```bash
# Pods ingress-nginx
kubectl get pods -n ingress-nginx

# Service LoadBalancer
kubectl get svc -n ingress-nginx

# IngressClass
kubectl get ingressclass

# Ingress resources
kubectl get ingress --all-namespaces
```

### Vérifier un Ingress

```bash
# Status de l'Ingress
kubectl describe ingress my-app -n default

# Logs controller
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Accès via IP LoadBalancer
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -H "Host: app.example.com" http://$INGRESS_IP
```

### Métriques

```bash
# Port-forward vers les métriques
kubectl port-forward -n ingress-nginx deployment/ingress-nginx-controller 10254:10254

# Accéder aux métriques
curl http://localhost:10254/metrics
```

## Troubleshooting

### Ingress pas accessible

**Problème**: L'ingress n'est pas accessible depuis l'extérieur

**Vérifications**:
```bash
# Service LoadBalancer a une IP externe ?
kubectl get svc -n ingress-nginx

# Pods controller en Running ?
kubectl get pods -n ingress-nginx

# Logs controller
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Backend service existe ?
kubectl get svc -n <namespace>

# DNS résolu correctement ?
nslookup app.example.com
```

### 502 Bad Gateway

**Problème**: nginx retourne 502 Bad Gateway

**Causes courantes**:
- Backend service down
- Backend pod pas ready
- Mauvais nom de service dans l'Ingress
- Backend timeout

**Solution**:
```bash
# Vérifier les pods backend
kubectl get pods -n <namespace>

# Vérifier les endpoints
kubectl get endpoints -n <namespace>

# Logs backend
kubectl logs -n <namespace> <pod-name>

# Augmenter les timeouts si nécessaire
kubectl annotate ingress my-app nginx.ingress.kubernetes.io/proxy-read-timeout="300"
```

### 413 Request Entity Too Large

**Problème**: Upload de fichier échoue avec 413

**Solution**:
```bash
# Augmenter proxy-body-size (per Ingress)
kubectl annotate ingress my-app nginx.ingress.kubernetes.io/proxy-body-size="50m"

# Ou globalement dans config-dev.yaml
ingressNginx:
  controller:
    config:
      proxy-body-size: "100m"
```

### Certificat TLS pas généré

**Problème**: Cert-manager ne génère pas le certificat

**Vérifications**:
```bash
# Certificate resource créé ?
kubectl get certificate -n <namespace>

# CertificateRequest
kubectl get certificaterequest -n <namespace>

# Logs cert-manager
kubectl logs -n cert-manager deployment/cert-manager

# Annotation cluster-issuer présente ?
kubectl get ingress my-app -o yaml | grep cert-manager
```

### Rate Limiting pas appliqué

**Problème**: Rate limiting ne fonctionne pas

**Vérifications**:
```bash
# Annotations présentes ?
kubectl get ingress my-app -o yaml | grep limit

# ConfigMap nginx-configuration
kubectl get configmap -n ingress-nginx

# Logs controller (vérifier les requêtes)
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --tail=100
```

### Configuration NGINX pas rechargée

**Problème**: Alert `NGINXConfigFailed`

**Solution**:
```bash
# Vérifier la config NGINX
kubectl exec -n ingress-nginx deployment/ingress-nginx-controller -- nginx -t

# Identifier l'Ingress problématique
kubectl get events -n ingress-nginx --sort-by='.lastTimestamp'

# Supprimer ou corriger l'Ingress problématique
kubectl delete ingress <problematic-ingress> -n <namespace>

# Forcer le reload
kubectl rollout restart deployment/ingress-nginx-controller -n ingress-nginx
```

## Métriques Prometheus

Principales métriques exposées (port 10254):

**Controller:**
- `nginx_ingress_controller_config_last_reload_successful`: Status du dernier reload (0/1)
- `nginx_ingress_controller_requests`: Nombre total de requêtes (par status, method, host)
- `nginx_ingress_controller_request_duration_seconds`: Latence des requêtes
- `nginx_ingress_controller_response_size`: Taille des réponses
- `nginx_ingress_controller_ssl_expire_time_seconds`: Timestamp d'expiration des certificats SSL

**Nginx:**
- `nginx_ingress_controller_nginx_process_connections`: Connexions actives, reading, writing, waiting
- `nginx_ingress_controller_nginx_process_cpu_seconds_total`: CPU usage
- `nginx_ingress_controller_nginx_process_resident_memory_bytes`: Memory usage

**Backend:**
- `nginx_ingress_controller_success`: Backend health check success/failure

## Exemples Complets

### Application avec monitoring

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
  replicas: 2
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
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/rate-limit: "100"
    nginx.ingress.kubernetes.io/limit-rps: "10"
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - httpbin.example.com
    secretName: httpbin-tls
  rules:
  - host: httpbin.example.com
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

## Configuration Avancée

### TCP/UDP Services

Pour exposer des services TCP/UDP (ex: GitLab SSH):

```yaml
# ConfigMap tcp-services
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ingress-nginx
data:
  22: "gitlab/gitlab-gitlab-shell:22"
```

Puis ajouter dans le chart:
```yaml
tcp:
  22: "gitlab/gitlab-gitlab-shell:22"
```

### Custom Default Backend

Remplacer la page 404 par défaut:
```yaml
ingressNginx:
  defaultBackend:
    enabled: true
    image:
      repository: my-custom-404-page
      tag: latest
```

## Docs

- [Ingress-NGINX Documentation](https://kubernetes.github.io/ingress-nginx/)
- [User Guide: Monitoring](https://kubernetes.github.io/ingress-nginx/user-guide/monitoring/)
- [ConfigMap Options](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/)
- [Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [Grafana Dashboard 9614](https://grafana.com/grafana/dashboards/9614)
