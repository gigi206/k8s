# Cert-Manager - Certificate Management

Cert-Manager gère automatiquement les certificats TLS dans Kubernetes, avec support Let's Encrypt, self-signed, et autres CA.

## Dépendances

### Automatiques (via ApplicationSets)
Ces composants sont des dépendances de cette application:

- **Prometheus Stack**: Pour le monitoring cert-manager
 - ServiceMonitor et PrometheusRule déployés si `features.monitoring.enabled: true`
 - Dashboard Grafana automatiquement chargé
 - Alertes automatiques pour certificats expirés/non-ready

### Manuelles

Aucune dépendance manuelle. Cert-Manager fonctionne avec les CRDs incluses dans le chart.

## Configuration

### Environnements

**Dev (`config-dev.yaml`):**
- 1 replica pour tous les composants (controller, webhook, cainjector)
- Resources minimales (10m CPU, 32-64Mi memory)
- Gateway API support activé
- Auto-sync activé

**Prod (`config-prod.yaml`):**
- 3 replicas pour HA (controller, webhook, cainjector)
- Resources plus élevées (50-200m CPU, 128-256Mi memory)
- Gateway API support activé
- Auto-sync désactivé (manual)

### Gateway API Support

Depuis cert-manager v1.15+, le Gateway API support n'est plus expérimental:
- **v1.14 et avant**: Feature gate `ExperimentalGatewayAPISupport=true`
- **v1.15+**: Configuration `config.enableGatewayAPI=true`

Notre configuration (v1.19.1) utilise la nouvelle méthode stable.

Pour activer/désactiver:
```yaml
# Dans config-dev.yaml ou config-prod.yaml
certManager:
  gatewayAPI:
    enabled: true  # ou false
```

## ClusterIssuers

### Self-Signed Issuer (Dev par défaut)

ClusterIssuer pour certificats auto-signés, utilisé en dev:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-cluster-issuer
spec:
  selfSigned: {}
```

### Let's Encrypt (Staging et Prod)

Deux ClusterIssuers Let's Encrypt sont configurés:

**Staging (pour tests):**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
   - http01:
        ingress:
          class: nginx
```

**Production:**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
   - http01:
        ingress:
          class: nginx
```

Configuration dans `config.yaml`:
```yaml
common:
  certEmail: "admin@example.com"
  clusterIssuer: "selfsigned-cluster-issuer"  # ou letsencrypt-staging, letsencrypt-prod
```

## Utilisation

### Certificat pour Ingress

Ajouter les annotations à votre Ingress:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
 - hosts:
   - example.com
    secretName: example-com-tls
  rules:
 - host: example.com
    http:
      paths:
     - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
```

Cert-manager créera automatiquement le certificat et le secret `example-com-tls`.

### Certificat manuel

Créer un Certificate resource:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-certificate
  namespace: default
spec:
  secretName: my-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
 - example.com
 - www.example.com
```

### Gateway API (v1.15+)

Avec Gateway API support activé:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  gatewayClassName: nginx
  listeners:
 - name: https
    protocol: HTTPS
    port: 443
    hostname: example.com
    tls:
      mode: Terminate
      certificateRefs:
     - name: example-com-tls
```

## Monitoring

### Prometheus

Si `features.monitoring.enabled: true`, les ressources suivantes sont déployées:

**ServiceMonitor:**
- Collecte les métriques cert-manager depuis le controller

**PrometheusRule (5 Alertes):**
- `CertManagerAbsent` (critical): Cert-Manager disparu de Prometheus
- `CertManagerCertificateReadyStatus` (critical): Certificat pas ready
- `CertManagerCertNotReady` (critical): Certificat pas ready depuis 10m
- `CertManagerCertExpirySoon` (warning): Certificat expire dans < 21 jours
- `CertManagerHittingRateLimits` (critical): Atteint les rate limits Let's Encrypt

### Grafana Dashboard

Le dashboard Grafana est automatiquement chargé via ConfigMap avec le label `grafana_dashboard: "1"`.

**Panneaux disponibles:**
- Certificates Ready: Nombre de certificats ready
- Soonest Cert Expiry: Expiration la plus proche
- Certificates: Liste des certificats
- Controller Sync Requests/sec: Métriques du controller
- ACME HTTP Requests/sec: Requêtes ACME
- ACME HTTP Request avg duration: Latence ACME
- CPU, Memory, Network: Métriques resources

**Note:** Some parts of the dashboard are not functional and need work.

## Vérification

### Vérifier le déploiement

```bash
# Pods cert-manager
kubectl get pods -n cert-manager

# ClusterIssuers
kubectl get clusterissuer

# Certificats
kubectl get certificate --all-namespaces
```

### Vérifier un certificat

```bash
# Status du certificat
kubectl describe certificate my-certificate

# Secret TLS créé
kubectl get secret my-tls-secret -o yaml

# Vérifier l'expiration
kubectl get certificate my-certificate -o jsonpath='{.status.notAfter}'
```

### Logs

```bash
# Controller logs
kubectl logs -n cert-manager deployment/cert-manager

# Webhook logs
kubectl logs -n cert-manager deployment/cert-manager-webhook

# CA Injector logs
kubectl logs -n cert-manager deployment/cert-manager-cainjector
```

## Troubleshooting

### Certificat pas créé

**Problème**: Le certificat reste en `Ready: False`

**Vérifications**:
```bash
# Status détaillé
kubectl describe certificate my-certificate

# Events
kubectl get events -n default --sort-by='.lastTimestamp'

# CertificateRequest
kubectl get certificaterequest

# Order (pour ACME)
kubectl get order

# Challenge (pour ACME)
kubectl get challenge
```

### ACME HTTP-01 Challenge échoue

**Problème**: Let's Encrypt ne peut pas valider le challenge HTTP-01

**Causes courantes**:
- Ingress non accessible depuis Internet
- Firewall bloque le port 80/443
- DNS pas correctement configuré

**Solution**:
```bash
# Vérifier l'Ingress
kubectl get ingress

# Vérifier le service
kubectl get svc -n cert-manager

# Tester l'accès HTTP (depuis l'extérieur)
curl http://example.com/.well-known/acme-challenge/test

# Logs du challenge
kubectl describe challenge <challenge-name>
```

### Rate Limits Let's Encrypt

**Problème**: Alert `CertManagerHittingRateLimits`

**Solution**:
- Utiliser `letsencrypt-staging` pour les tests
- Let's Encrypt limite: 50 certificats/domaine/semaine
- Attendre la réinitialisation du rate limit (1 semaine max)

### Gateway API pas supporté

**Problème**: Gateway API resources non reconnus

**Vérifications**:
```bash
# Gateway API CRDs installées ?
kubectl get crd gateways.gateway.networking.k8s.io

# Gateway API support activé ?
# Vérifier dans config-dev.yaml ou config-prod.yaml:
# certManager.gatewayAPI.enabled: true

# Redémarrer cert-manager après installation des CRDs
kubectl rollout restart deployment/cert-manager -n cert-manager
```

## Métriques Prometheus

Principales métriques exposées (port 9402):

- `certmanager_certificate_ready_status`: Status des certificats (condition=True/False)
- `certmanager_certificate_expiration_timestamp_seconds`: Timestamp d'expiration
- `certmanager_controller_sync_call_count`: Nombre d'appels de sync
- `certmanager_http_acme_client_request_count`: Requêtes ACME
- `certmanager_http_acme_client_request_duration_seconds`: Latence ACME

## Exemples

### Application avec TLS (httpbin)

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
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
spec:
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
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-staging"
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

## Docs

- [Cert-Manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Gateway API Support](https://cert-manager.io/docs/usage/gateway/)
- [Prometheus Metrics](https://cert-manager.io/docs/devops-tips/prometheus-metrics/)
- [Monitoring Mixins](https://monitoring.mixins.dev/cert-manager/)
