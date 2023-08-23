# gateway-api

* https://gateway-api.sigs.k8s.io/guides/
* https://github.com/kubernetes-sigs/gateway-api/tree/main/config/crd

## cert-manager
* https://cert-manager.io/docs/usage/gateway/

## external-dns
* https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/gateway-api.md

## Demo
* Demo from https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/

```bash
$ kubectl create ns demo
$ kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.18/samples/httpbin/httpbin.yaml -n demo
$ kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: gateway
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  listeners:
  - name: default
    hostname: "*.example.com"
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: http
  namespace: demo
spec:
  parentRefs:
  - name: gateway
    namespace: istio-ingress
  hostnames: ["httpbin.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /get
    backendRefs:
    - name: httpbin
      port: 8000
EOF
```

```bash
$ curl -IH "host: httpbin.example.com" http://$(kubectl get gateways.gateway.networking.k8s.io http-gateway -n istio-ingress -ojsonpath='{.status.addresses[0].value}')/get
HTTP/1.1 200 OK
server: istio-envoy
date: Tue, 01 Aug 2023 13:29:58 GMT
content-type: application/json
content-length: 658
access-control-allow-origin: *
access-control-allow-credentials: true
x-envoy-upstream-service-time: 1
```
