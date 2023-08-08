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

## Install bookinfo demo app

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
sed -e "s@istio: ingressgateway@istio: $(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.metadata.labels.istio}')@g" -e "s@number: 8080@number: $(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath="{.spec.ports[?(@.name=='http2')].port}")@g" samples/bookinfo/networking/bookinfo-gateway.yaml | kubectl apply -n bookinfo -f -
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
