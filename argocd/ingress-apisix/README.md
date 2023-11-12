# APISIX
## Debug
```shell
kubectl -n ingress-apisix logs deployments/ingress-apisix-ingress-controller -f
```

## Issues
### Issue when starting with Longhorn
Statefulset `ingress-apisix-etcd` refused to start:
```shell
$ kubectl -n ingress-apisix scale statefulset ingress-apisix-etcd --replicas 0
$ kubectl rollout status -n ingress-apisix statefulset ingress-apisix-etcd
$ kubectl -n ingress-apisix scale statefulset ingress-apisix-etcd --replicas 0
```

### tcproutes / udproutes are missing from clusterrole
For obscur reasons `tcproutes` and `udproutes` are missings from the `ingress-apisix-clusterrole` `ClusterRole` when I deployed from ArgoCD and I need patched to add them:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ingress-apisix-clusterrole
rules:
...
  - apiGroups:
      - gateway.networking.k8s.io
    resources:
      - tcproutes
      - udproutes
      - httproutes
      - tlsroutes
      - gateways
      - gatewayclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - gateway.networking.k8s.io
    resources:
      - tcproutes/status
      - udproutes/status
      - httproutes/status
      - tlsroutes/status
      - gateways/status
      - gatewayclasses/status
    verbs:
      - update
...
```

### Github issues
* ["k8s.apisix.apache.org/upstream-scheme: https" seems not working with Kubernetes Ingress](https://github.com/apache/apisix-ingress-controller/issues/2033)
* [gateway (gateway.networking.k8s.io/v1beta1) does not create the TLS entry](https://github.com/apache/apisix/issues/10447)
* [ingress-controller crash when a HTTPRoute is created](https://github.com/apache/apisix-ingress-controller/issues/2037)
* [apisix standalone mode (without etcd) on kubernetes does not work](https://github.com/apache/apisix-ingress-controller/issues/2036)

# Mode standalone not working
* https://github.com/apache/apisix-ingress-controller/issues/2036

## Hot reloading
* Hot reloading (hitless restart): https://api7.ai/blog/how-nginx-reload-work

## Customize Nginx configuration
* https://apisix.apache.org/docs/apisix/customize-nginx-configuration/

## Plugins
* https://apisix.apache.org/docs/apisix/terminology/plugin
  * [Hot reload plugins](https://apisix.apache.org/docs/apisix/terminology/plugin/#hot-reload)
* [Set plugins for Ingress](https://apisix.apache.org/docs/ingress-controller/concepts/annotations/#using-apisixpluginconfig-resource)

### client-control
* https://apisix.apache.org/docs/apisix/plugins/client-control/
* Set the `max_body_size`: https://apisix.apache.org/docs/apisix/plugins/client-control/#attributes

### batch-requests
* https://apisix.apache.org/docs/apisix/plugins/batch-requests/
* Set the `max_body_size`: https://apisix.apache.org/docs/apisix/plugins/batch-requests/#configuration

## Tuto
* Define `INGRESS_HOST` and `INGRESS_PORT` variables:
```shell
$ INGRESS_HOST=$(kubectl get svc -n ingress-apisix ingress-apisix-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ INGRESS_PORT=$(kubectl get svc -n ingress-apisix ingress-apisix-gateway -o jsonpath="{.spec.ports[?(@.name=='apisix-gateway')].port}")
```

* All examples use the `httpbin` app:
```shell
$ kubectl create ns httpbin
$ kubectl apply -n httpbin -f https://raw.githubusercontent.com/istio/istio/master/samples/httpbin/httpbin.yaml
```

### All in one
```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: demo
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
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
  name: httpbin3
  namespace: demo
spec:
  ingressClassName: apisix
  rules:
  - host: httpbin3.gigix
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
    - httpbin3.gigix
    secretName: httpbin3-cert-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: httpbin2-cert-tls
  namespace: demo
spec:
  dnsNames:
    - httpbin2.gigix
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-cluster-issuer
  secretName: httpbin2-cert-tls
  usages:
    - digital signature
    - key encipherment
---
apiVersion: apisix.apache.org/v2
kind: ApisixTls
metadata:
  name: httpbin2-tls
  namespace: demo
spec:
  hosts:
  - httpbin2.gigix
  secret:
    name: httpbin2-cert-tls
    namespace: demo
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: httpbin2
  namespace: demo
spec:
  http:
    - name: httpbin2
      match:
        hosts:
          - httpbin2.gigix
        paths:
          - /*
      backends:
        - serviceName: httpbin
          servicePort: 8000
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
spec:
  gatewayClassName: apisix
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
  - protocol: HTTPS
    name: https
    port: 443
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
apiVersion: gateway.networking.k8s.io/v1beta1
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

### Kubernetes Ingress
* Ingress annotations: https://apisix.apache.org/docs/ingress-controller/concepts/annotations/

**Warning:** when Ingress is defined with `pathType: ImplementationSpecific`, you must add the annotation `k8s.apisix.apache.org/use-regex: "true"`

* Verify that the `ingressClass` **apisix** is created:
```shell
$ kubectl get ingressclass apisix
NAME     CONTROLLER                         PARAMETERS   AGE
apisix   apisix.apache.org/apisix-ingress   <none>       16m
```

* If not, create it:
```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: apisix
spec:
  controller: apisix.apache.org/apisix-ingress
```

* Create the `Ingress`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
  name: httpbin
  namespace: httpbin
spec:
  ingressClassName: apisix
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

* Test the ingress:
```shell
$ curl -I -HHost:httpbin.gigix --resolve "httpbin.gigix:${INGRESS_PORT}:${INGRESS_HOST}" http://httpbin.gigix
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 9593
Connection: keep-alive
Date: Thu, 02 Nov 2023 14:58:16 GMT
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Server: APISIX/3.6.0
```

### Kubernetes Gateway API
[Gateway API](../gateway-api-controller/gateway-api-controller.yaml) must be installed.

* https://apisix.apache.org/docs/ingress-controller/tutorials/configure-ingress-with-gateway-api/

#### Gateway
* Verify that a `GatewayClass` exists first:
```shell
$ kubectl get GatewayClass apisix
NAME     CONTROLLER                             ACCEPTED   AGE
apisix   apisix.apache.org/gateway-controller   True       44h
```

* Or create it:
```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: apisix
spec:
  # https://github.com/apache/apisix-ingress-controller/blob/master/pkg/config/config.go#L59C20-L59C56
  controllerName: apisix.apache.org/gateway-controller
```

* And a `Gateway` that refers to a `GatewayClass`:
```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: httpbin
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
spec:
  gatewayClassName: apisix
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
  - protocol: HTTPS
    name: https
    port: 443
    hostname: "httpbin.gigix"
    tls:
      mode: Terminate
      certificateRefs:
        - name: httpbin-cert-tls
          kind: Secret
          group: core
    allowedRoutes:
      namespaces:
        from: Same
```

* Verify:
```shell
$ kubectl get Gateway -n httpbin httbin-gateway
NAME             CLASS    ADDRESS          PROGRAMMED   AGE
apisix-gateway   apisix   192.168.122.89   True         2d
```

#### HTTPRoute
* Set the `HTTPRoute` that refers to a `Gateway`:
```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: httpbin
spec:
  hostnames:
  - httpbin.gigix
  parentRefs:
  - name: httpbin-gateway
    namespace: httpbin
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin
      port: 8000
```

### Apisix
* https://apisix.apache.org/docs/ingress-controller/concepts/apisix_route/
* https://apisix.apache.org/docs/ingress-controller/references/apisix_route_v2/

```yaml
kind: Certificate
metadata:
  name: httpbin-cert-tls
  namespace: httpbin
spec:
  dnsNames:
    - httpbin.gigix
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-cluster-issuer
  secretName: httpbin-cert-tls
  usages:
    - digital signature
    - key encipherment
---
apiVersion: apisix.apache.org/v2
kind: ApisixTls
metadata:
  name: httpbin
  namespace: httpbin
spec:
  hosts:
  - httpbin.gigix
  secret:
    name: httpbin-cert-tls
    namespace: httpbin
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: httpbin
  namespace: httpbin
spec:
  http:
    - name: httpbin
      match:
        hosts:
          - httpbin.gigix
        paths:
          - /*
      backends:
        - serviceName: httpbin
          servicePort: 8000
```



* Test the route to access httpbin application:
```shell
$ curl -I -HHost:httpbin.gigix --resolve "httpbin.gigix:${INGRESS_PORT}:${INGRESS_HOST}" http://httpbin.gigix
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 9593
Connection: keep-alive
Date: Thu, 02 Nov 2023 14:18:48 GMT
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Server: APISIX/3.6.0
```

##### ApisixUpstream
* https://apisix.apache.org/docs/ingress-controller/concepts/apisix_upstream/

Example with force to set https upstream for the backend service:
```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixUpstream
metadata:
  name: argo-cd-argocd-server
  namespace: argo-cd
spec:
  scheme: https
  #loadbalancer:
  #  type: roundrobin
```