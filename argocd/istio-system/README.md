# Istio
## Examples of use cases
* https://istiobyexample.dev

## Ambient mode
Ambient mode allow to use istio without sidecar proxy (alpha).
* https://istio.io/latest/docs/ops/ambient/getting-started/

## Sidecar inject
* [Controlling the injection policy](https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/#controlling-the-injection-policy)
* [Manual sidecar injection](https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/#manual-sidecar-injection)

## cert-manager
* https://cert-manager.io/docs/usage/istio/
* https://cert-manager.io/docs/tutorials/istio-csr/istio-csr/
* https://github.com/cert-manager/istio-csr

For certificate secret format please read https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/#key-formats

## external-dns
* https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/istio.md

## Grafana
* https://istio.io/latest/docs/ops/integrations/grafana/

All dashboards:
* (7639) [Mesh Dashboard](https://grafana.com/grafana/dashboards/7639) provides an overview of all services in the mesh.
* (7636) [Service Dashboard](https://grafana.com/grafana/dashboards/7636) provides a detailed breakdown of metrics for a service.
* (7630) [Workload Dashboard](https://grafana.com/grafana/dashboards/7630) provides a detailed breakdown of metrics for a workload.
* (11829) [Performance Dashboard](https://grafana.com/grafana/dashboards/11829) monitors the resource usage of the mesh.
* (7645) [Control Plane Dashboard](https://grafana.com/grafana/dashboards/7645) monitors the health and performance of the control plane.
* (13277) [Istio Wasm Extension Dashboard](https://grafana.com/grafana/dashboards/13277-istio-wasm-extension-dashboard/)

## Istioctl
### Download
```bash
curl -L https://istio.io/downloadIstio | sh -
```
Or specify version and arch:
```bash
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.17.1 TARGET_ARCH=x86_64 sh -
cp istio-1.17.1/bin/istioctl /usr/local/bin/
```

## K8S Gateway API
Cf https://istio.io/latest/docs/examples/bookinfo/#before-you-begin

> Istio includes beta support for the Kubernetes Gateway API and intends to make it the default API for traffic management in the future. The following instructions allow you to choose to use either the Gateway API or the Istio configuration API when configuring traffic management in the mesh. Follow instructions under either the Gateway API or Istio classic tab, according to your preference.

> Note that the Kubernetes Gateway API CRDs do not come installed by default on most Kubernetes clusters, so make sure they are installed before using the Gateway API:

Cf installation of [gateway-api-controller](../gateway-api-controller/) via ArgoCD.

```bash
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v0.6.1" | kubectl apply -f -; }
```

## Tutorial
### Install bookinfo demo app
Cf https://istio.io/latest/docs/examples/bookinfo/#before-you-begin

* Download source from Github:
```bash
git clone --depth=1 https://github.com/istio/istio
cd istio
```

* Create NS `bookinfo`:
```bash
kubectl create ns bookinfo
kubectl label namespace bookinfo istio-injection=enabled
```

* Deploy the application:
```bash
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml -n bookinfo
```

If you disabled automatic sidecar injection during installation use the `istioctl kube-inject`:
```bash
kubectl apply -f <(istioctl kube-inject -f samples/bookinfo/platform/kube/bookinfo.yaml) -n bookinfo
```

Ensure the app is deployed and running:
```bash
kubectl -n bookinfo exec "$(kubectl -n bookinfo get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')" -c ratings -- curl -sS productpage:9080/productpage | grep -o "<title>.*</title>"
<title>Simple Bookstore App</title>
```

* Configure env vars:
```bash
# export INGRESS_NAME=istio-ingressgateway
export INGRESS_NAME=istio-ingress
export INGRESS_NS=istio-ingress
export INGRESS_HOST=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
export TCP_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
```

* Create an Istio Gateway to access the Bookinfo application from outside the kubernetes cluster (fix the issue by replacing the `istio` label from `ingressgateway` to `ingress` and replace the port number from 8080 to 80):
```bash
sed -e "s@istio: ingressgateway@istio: $(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.metadata.labels.istio}')@g" -e "s@number: 8080@number: $(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath="{.spec.ports[?(@.name=='http2')].port}")@g" samples/bookinfo/networking/bookinfo-gateway.yaml | egrep -v 'prometheus.io' | kubectl apply -n bookinfo -f -
```

By defaut the port number of the gateway is `8080` but no service listen on this port (only `80`, `443` and `15021` by the service `istio-ingress`). If you want access to port 8080 you must create a service on the namespace `istio-ingress`:
```yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    app: istio-ingress-8080
    istio: ingress2
  namespace: istio-ingress
spec:
  ports:
  - name: http2
    port: 8080
    protocol: TCP
    targetPort: 80
  selector:
    app: istio-ingress
    istio: ingress
  type: LoadBalancer
```

Now you can access the bookinfo application with the browser from the following URL:
```bash
echo http://${GATEWAY_URL}/productpage
http://192.168.122.204:80/productpage
```

* Istio uses subsets, in destination rules, to define versions of a service. Run the following command to create default destination rules for the Bookinfo services:
```bash
kubectl apply -f samples/bookinfo/networking/destination-rule-all.yaml -n bookinfo
```

### TLS
#### TLS terminaison whith TLS backend
* Example for ArgoCD with TLS backend enabled:
```yaml
#apiVersion: security.istio.io/v1beta1
#kind: PeerAuthentication
#metadata:
#  name: argocd
#  namespace: argo-cd
#spec:
#  mtls:
#    mode: DISABLE
#---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: argocd
  namespace: argo-cd
spec:
  host: argo-cd-argocd-server
  trafficPolicy:
    tls:
      mode: DISABLE
      # mode: SIMPLE
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd
  namespace: istio-system
spec:
  dnsNames:
    - argocd.gigix
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-cluster-issuer
  secretName: argocd-cert-tls
  usages:
    - digital signature
    - key encipherment
---
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: argocd
  namespace: argo-cd
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - argocd.gigix
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      #mode: MUTUAL
      #mode: PASSTHROUGH
      credentialName: argocd-cert-tls
    hosts:
    - argocd.gigix
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: argocd
  namespace: argo-cd
spec:
  hosts:
  - argocd.gigix
  gateways:
  - argocd
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        port:
          number: 443
        host: argo-cd-argocd-server
```

# TLS PASSTHROUGH
* https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/

#### httpbin
* Deploy this example for `Ingress`, API and Istio `Gateway`:
  * **httpbin.gigix**: API Gateway
  * **httpbin2.gigix**: ISTIO Gateway
  * **httpbin3.gigix**: Kubernetes Ingress

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
      #serviceAccountName: httpbin
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: httpbin-cert-tls
  namespace: demo
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
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: httpbin2-cert-tls
  namespace: istio-system
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
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: httpbin3-cert-tls
  namespace: istio-system
spec:
  dnsNames:
    - httpbin3.gigix
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-cluster-issuer
  secretName: httpbin3-cert-tls
  usages:
    - digital signature
    - key encipherment
---
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: httpbin2-gateway
  namespace: demo
spec:
  # The selector matches the ingress gateway pod labels.
  # If you installed Istio using Helm following the standard documentation, this would be "istio=ingress"
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - httpbin2.gigix
    tls:
      httpsRedirect: true
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      #mode: MUTUAL
      #mode: PASSTHROUGH
      credentialName: httpbin2-cert-tls
    hosts:
    - httpbin2.gigix
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: httpbin2
  namespace: demo
spec:
  hosts:
  - httpbin2.gigix
  gateways:
  - httpbin2-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        port:
          number: 8000
        host: httpbin
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
  #namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
    #    from: All
    #    from: Selector
    #    selector:
    #      matchLabels:
    #        kubernetes.io/metadata.name: demo
  - name: https
    protocol: HTTPS
    port: 443
    hostname: httpbin.gigix
    tls:
      mode: Terminate
      #mode: Passthrough
      #options:
      #  gateway.istio.io/tls-terminate-mode: MUTUAL
      certificateRefs:
        - name: httpbin-cert-tls
          kind: Secret
          #group: core # doesn't work with istio
          group: ""
    allowedRoutes:
      namespaces:
        from: Same
    #    from: All
    #    from: Selector
    #    selector:
    #      matchLabels:
    #        kubernetes.io/metadata.name: demo
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
    #namespace: istio-system
  rules:
  # - filters:
  #     - type: RequestRedirect
  #       requestRedirect:
  #         scheme: https
  #         statusCode: 301
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin
      port: 8000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  #annotations: # certificate must be created in the istio-system namespace
  #  cert-manager.io/cluster-issuer: selfsigned-cluster-issuer
  name: httpbin3
  namespace: demo
spec:
  ingressClassName: istio
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
```

##### GATEWAY API
* **Warning:**: Certificate must be created in the `demo` namespace:

The Gateway API is configured for the hostname **httpbin.gigix**.
```shell
export GATEWAY_HOSTNAME=httpbin.gigix
export GATEWAY_NAME=httpbin-gateway
export GATEWAY_NS=demo
export GATEWAY_HOST=$(kubectl get -n ${GATEWAY_NS} gateways.gateway.networking.k8s.io ${GATEWAY_NAME} -o jsonpath='{.status.addresses[0].value}')
export GATEWAY_PORT=$(kubectl get -n ${GATEWAY_NS} gateways.gateway.networking.k8s.io ${GATEWAY_NAME} -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export SECURE_GATEWAY_PORT=$(kubectl get gateways.gateway.networking.k8s.io -n ${GATEWAY_NS} ${GATEWAY_NAME} -o jsonpath='{.spec.listeners[?(@.name=="https")].port}')
```

* GATEWAY API HTTP:
```shell
curl -Ik --resolve "${GATEWAY_HOSTNAME}:${GATEWAY_PORT}:${GATEWAY_HOST}" http://${GATEWAY_HOSTNAME}:${GATEWAY_PORT}
```

* GATEWAY API HTTPS:
```shell
curl -Ik --resolve "${GATEWAY_HOSTNAME}:${SECURE_GATEWAY_PORT}:${GATEWAY_HOST}" https://${GATEWAY_HOSTNAME}:${SECURE_GATEWAY_PORT}
```

##### Istio GATEWAY
* **Warning:** Certificate must be created in the `istio-system` namespace and **NOT** in the **demo** namespace:

The Istio Gateway is configured for the hostname **httpbin2.gigix**:
```shell
export ISTIO_INGRESS_HOSTNAME=httpbin2.gigix
export ISTIO_INGRESS_NAME=istio-ingressgateway
export ISTIO_INGRESS_NS=istio-system
export ISTIO_INGRESS_HOST=$(kubectl -n "${ISTIO_INGRESS_NS}" get service "${ISTIO_INGRESS_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export ISTIO_INGRESS_PORT=$(kubectl -n "${ISTIO_INGRESS_NS}" get service "${ISTIO_INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export ISTIO_SECURE_INGRESS_PORT=$(kubectl -n "${ISTIO_INGRESS_NS}" get service "${ISTIO_INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
```

* ISTIO GW HTTP (redirect to https):
```shell
curl -Ik --resolve "${ISTIO_INGRESS_HOSTNAME}:${ISTIO_INGRESS_PORT}:${ISTIO_INGRESS_HOST}" http://${ISTIO_INGRESS_HOSTNAME}:${ISTIO_INGRESS_PORT}
```

* ISTIO GW HTTPS:
```shell
curl -Ik --resolve "${ISTIO_INGRESS_HOSTNAME}:${ISTIO_SECURE_INGRESS_PORT}:${ISTIO_INGRESS_HOST}" https://${ISTIO_INGRESS_HOSTNAME}:${ISTIO_SECURE_INGRESS_PORT}
```

##### Ingress (Kubernetes)
* **Warning:**: Certificate must be created in the `istio-system` namespace (and **NOT** in the **demo** namespace) and **before** the istio `istio-ingressgateway` starts:

The Ingress is configured for the hostname **httpbin3.gigix**:
```shell
export INGRESS_HOSTNAME=httpbin3.gigix
export INGRESS_NAME=httpbin3
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