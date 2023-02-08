# ingress-nginx

## Dependencies
* [prometheus-stack](/argocd/prometheus-stack/prometheus-stack.yaml) (required by the CRDs used by the **prometheus-stack**)

## Monitoring
Please read the [documentation](https://kubernetes.github.io/ingress-nginx/user-guide/monitoring/).

You must install the [grafana dashboard](https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/grafana/dashboards/nginx.json).

You can use a specific dashboard version https://github.com/kubernetes/ingress-nginx/blob/helm-chart-`<tag>`/deploy/grafana/dashboards/nginx.json, example https://github.com/kubernetes/ingress-nginx/blob/helm-chart-4.2.1/deploy/grafana/dashboards/nginx.json.

## Annotations
https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/

### Rate limiting
https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#rate-limiting

Requests can be limited per second (rps for request by second) or per minute (rpm for request per minute):
```yaml
nginx.ingress.kubernetes.io/limit-rps: "5"
nginx.ingress.kubernetes.io/limit-rpm: "300"
nginx.ingress.kubernetes.io/limit-connections: "10"
```

### SSL redirection
`http` protocol can be automatically redirected on `https`:
```yaml
nginx.ingress.kubernetes.io/rewrite-target: /
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
nginx.ingress.kubernetes.io/ssl-redirect: "true"
nginx.ingress.kubernetes.io/preserve-trailing-slash: "true"
```

### Timeout
```yaml
nginx.org/proxy-connect-timeout: "30s"
nginx.org/proxy-read-timeout: "20s"
```

### Cors
```yaml
nginx.ingress.kubernetes.io/enable-cors: "true"
nginx.ingress.kubernetes.io/cors-allow-methods: "PUT, GET, POST, OPTIONS"
nginx.ingress.kubernetes.io/cors-allow-headers: "X-Forwarded-For, X-app123-XPTO"
nginx.ingress.kubernetes.io/cors-expose-headers: "*, X-CustomResponseHeader"
nginx.ingress.kubernetes.io/cors-max-age: 600
nginx.ingress.kubernetes.io/cors-allow-credentials: "false"
```

### Custom Max Body Size
```yaml
nginx.ingress.kubernetes.io/proxy-body-size: 8m
```

### Whitelist Source Range
Allow requests from a particular IP addresses:
```yaml
ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/24,172.10.0.1"
```

### Backend Protocol
You can use the backend protocol to specify how NGINX should communicate with the backend service. Valid values are `HTTP`, `HTTPS`, `GRPC`, `GRPCS`, `AJP`, and `FCGI`. By default, NGINX uses `HTTP`.
```yaml
nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
```
### Session affinity
```yaml
nginx.ingress.kubernetes.io/affinity: cookie
nginx.ingress.kubernetes.io/session-cookie-name: stickounet
nginx.ingress.kubernetes.io/session-cookie-expires: "172800"
nginx.ingress.kubernetes.io/session-cookie-max-age: "172800"
```

### configmap
https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/