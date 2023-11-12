# Traefik
* https://doc.traefik.io
* https://community.traefik.io

## Dashboard
* https://doc.traefik.io/traefik/operations/dashboard/
* By default the helm chart installs the following ingress `IngressRoute`:
```shell
kubectl get ingressroutes.traefik.io -n ingress-traefik ingress-traefik-dashboard -o yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ingress-traefik-dashboard
  namespace: ingress-traefik
spec:
  entryPoints:
  - traefik
  routes:
  - kind: Rule
    match: PathPrefix(`/dashboard`) || PathPrefix(`/api`)
    services:
    - kind: TraefikService
      name: api@internal
```

* By default the dashboard and API [is not exposed](https://artifacthub.io/packages/helm/traefik/traefik?modal=values&path=ports.traefik.expose) for security reasons (no kubernetes service created). To expose it you can use [port-forward](https://doc.traefik.io/traefik/user-guides/crd-acme/#port-forwarding) on the `Deployment`:
```shell
kubectl -n ingress-traefik port-forward deployments/ingress-traefik 9000:9000 #--address=0.0.0.0
```

* You can override:
  * [routes match](https://artifacthub.io/packages/helm/traefik/traefik?modal=values&path=ingressRoute.dashboard.matchRule)
  * [Middlewares](https://artifacthub.io/packages/helm/traefik/traefik?modal=values&path=ingressRoute.healthcheck.middlewares) to add Authentication
  * [TLS](https://artifacthub.io/packages/helm/traefik/traefik?modal=values&path=ingressRoute.healthcheck.tls)

## Architecture
![Architecture](https://doc.traefik.io/traefik/assets/img/architecture-overview.png)

### Plugins
* [Plugins](https://doc.traefik.io/traefik/plugins/)
* [Catalog](https://plugins.traefik.io/plugins)

### Providers
* [Kubernetes CRDs](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)
* [Kubernetes Ingress](https://doc.traefik.io/traefik/routing/providers/kubernetes-ingress/)
* [Kubernetes Gateway API](https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/)

### Entrypoints
* [Entrypoints](https://doc.traefik.io/traefik/routing/entrypoints/)

**INFO:** entrypoints are defined in [the section ports of the helm chart](https://artifacthub.io/packages/helm/traefik/traefik?modal=values&path=ports)

### Routers
* [Routers](https://doc.traefik.io/traefik/routing/routers/)

### Services
* [Services](https://doc.traefik.io/traefik/routing/services/)

### Middlewares
* [Middlewares](https://doc.traefik.io/traefik/middlewares/overview/)
* [HTTP](https://doc.traefik.io/traefik/middlewares/http/overview/)
* [TCP](https://doc.traefik.io/traefik/middlewares/tcp/overview/)

## Examples
### Kubernetes Ingress
* [Official documentation](https://doc.traefik.io/traefik/routing/providers/kubernetes-ingress/)

**INFO:** you can uncomment `traefik.ingress.kubernetes.io/router.entrypoints: websecure` to allow the traffic only on the **443** (https) port.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
spec:
  finalizers:
  - kubernetes
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: demo
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      # serviceAccountName: httpbin
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: demo
spec:
  redirectScheme:
    permanent: true
    port: "443"
    scheme: https
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpbin
  namespace: demo
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
    traefik.ingress.kubernetes.io/router.middlewares: demo-redirect-to-https@kubernetescrd
    # traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  rules:
  - host: httpbin.gigix
    http:
      paths:
      - backend:
          service:
            name: httpbin
            port:
              number: 8000
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - httpbin.gigix
    secretName: httpbin-cert-tls
```

```shell
export INGRESS_HOSTNAME=httpbin.gigix
export INGRESS_NAME=httpbin
export INGRESS_NS=demo
export INGRESS_HOST=$(kubectl -n ${INGRESS_NS} get ing ${INGRESS_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

* INGRESS HTTP:
```shell
curl -Ik --resolve "${INGRESS_HOSTNAME}:80:${INGRESS_HOST}" http://${INGRESS_HOSTNAME}
```
* INGRESS HTTPS:
```shell
curl -Ik --resolve "${INGRESS_HOSTNAME}:443:${INGRESS_HOST}" https://${INGRESS_HOSTNAME}
```

### Gateway API
* [Official documentation](https://doc.traefik.io/traefik/routing/providers/kubernetes-gateway/)

**Warning:** This is an **experimental** feature and at this moment ,it's impossible to create middleware with the Gateway API => https://github.com/traefik/traefik/issues/9417

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
spec:
  finalizers:
  - kubernetes
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: demo
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      # serviceAccountName: httpbin
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
spec:
  gatewayClassName: traefik
  listeners:
  - name: http
    protocol: HTTP
    port: 8000
    allowedRoutes:
      namespaces:
        from: Same
  - protocol: HTTPS
    name: https
    port: 8443
    hostname: httpbin.gigix
    tls:
      mode: Terminate
      certificateRefs:
        - name: httpbin-cert-tls
          kind: Secret
          group: core
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: demo
spec:
  hostnames:
  - httpbin.gigix
  parentRefs:
  - name: httpbin-gateway
    namespace: demo
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin
      port: 8000
```

### Custom Resource Definition (CRD)
* [Official documentation](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)

**INFO:** Change `external-dns.alpha.kubernetes.io/target` by your IP:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
spec:
  finalizers:
  - kubernetes
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: demo
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      #serviceAccountName: httpbin
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-to-https
  namespace: demo
spec:
  redirectScheme:
    permanent: true
    port: "443"
    scheme: https
---
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: httpbin
  namespace: demo
  annotations:
    external-dns.alpha.kubernetes.io/target: 192.168.122.66
    external-dns.alpha.kubernetes.io/hostname: httpbin.gigix
spec:
  entryPoints:
    - web
    - websecure
  #  - metrics
  routes:
    #- kind: Rule
    #  match: Host(`httpbin.gigix`) && PathPrefix(`/`)
    #  # priority: 1
    #  middlewares:
    #    - name: redirect-to-https
    #  services:
    #    - kind: TraefikService
    #      #name: noop@internal
    #      name: ping@internal
    - kind: Rule
      match: Host(`httpbin.gigix`) && PathPrefix(`/`)
      # priority: 2
      middlewares:
        - name: redirect-to-https
      services:
        - kind: Service
          name: httpbin
          namespace: demo
          port: 8000
```

* Example with routing to `ping@internal` Traefik service:
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: httpbin
  namespace: demo
spec:
  entryPoints:
    - web
    - websecure
  #  - metrics
  routes:
    - kind: Rule
     match: Host(`httpbin.gigix`) && PathPrefix(`/`)
     # priority: 1
     middlewares:
       - name: redirect-to-https
     services:
       - kind: TraefikService
         name: ping@internal
         #name: noop@internal
```

## Other examples
### GRPC
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: argocd2
  namespace: argo-cd
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`argocd2.gigix`)
      priority: 10
      services:
        - name: argo-cd-argocd-server
          port: 80
          scheme: http
    - kind: Rule
      match: Host(`argocd2.gigix`) && Headers(`Content-Type`, `application/grpc`)
      priority: 11
      services:
        - name: argo-cd-argocd-server
          port: 80
          scheme: h2c
```
### HTTPS backend
* Create the following `ServersTransport`:
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: ServersTransport
metadata:
  name: insecure-tls
  namespace: demo
spec:
    insecureSkipVerify: true
```

#### HTTPS backend with IngressRoute
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: argocd2
  namespace: argo-cd
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - kind: Rule
      match: Host(`argocd2.gigix`)
      middlewares:
        - name: redirect-to-https
          namespace: argo-cd
      services:
        - name: argo-cd-argocd-server
          port: 443
          serversTransport: insecure-tls
          scheme: https
```

#### HTTPS backend with Ingress
* Add these annotations to the `Service`:
```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    traefik.ingress.kubernetes.io/service.serversscheme: https
    traefik.ingress.kubernetes.io/service.serverstransport: demo-insecure-tls@kubernetescrd
```

* If `Ingress` add these annotations:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.middlewares: demo-redirect-to-https@kubernetescrd
```

### HTTPS passthrough
```yaml
kind: IngressRouteTCP
apiVersion: traefik.containo.us/v1alpha1
metadata:
  name: test
  namespace: argo-cd
spec:
  entryPoints:
    - websecure
  routes:
    - match: HostSNI(`demo.gigix`)
      services:
        - name: argo-cd-argocd-server
          namespace: argo-cd
          port: 443
  tls:
    passthrough: true
    # domains:
    #   - main: demo.gigix
    #   - sans:
    #     - demo-alternative1.gigix
    #     - demo-alternative2.gigix
    #     - demo-alternative3.gigix
```
