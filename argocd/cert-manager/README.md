# cert-manager
## Dependencies
* [prometheus-stack](/argocd/prometheus-stack/prometheus-stack.yaml) (required by the CRDs used by the **prometheus-stack**)

## Monitoring
The installation script `install.sh` installs some additionals `PrometheusRule` with the [prometheus.yaml](/argocd/cert-manager/prometheus.yaml) file.

Load the grafana dashboard with the [grafana.json](/argocd/cert-manager/grafana.json) file.

**important:** some parts of the dashboard are not fonctional and need work.

## Vault Issuer
* [Official documentation](https://cert-manager.io/docs/configuration/vault/)
* [Using Hashicorp Vault as a Certificate issuer in Cert Manager](https://medium.com/nerd-for-tech/using-hashicorp-vault-as-a-certificate-issuer-in-cert-manager-9e19d7239d3d)

## ACME
* [Cert-manager ACME documentation](https://cert-manager.io/docs/configuration/acme/)

### Solver http01
* [Cert-manager http01 documentation](https://cert-manager.io/docs/configuration/acme/http01/)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer # I'm using ClusterIssuer here
metadata:
  # name: letsencrypt-prod
  name: letsencrypt-staging
spec:
  acme:
    # server: https://acme-v02.api.letsencrypt.org/directory # prod
    server: https://acme-staging-v02.api.letsencrypt.org/directory # staging
    email: xxx@gmail.com
    privateKeySecretRef:
      # name: letsencrypt-prod
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
---
apiVersion: v1
kind: Namespace
metadata:
  name: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: httpbin
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
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        command:
        - gunicorn
        - -b
        - 0.0.0.0:8080
        - httpbin:app
        - -k
        - gevent
        env:
        - name: WORKON_HOME
          value: /tmp
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: httpbin
  labels:
    app: httpbin
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  selector:
    app: httpbin
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  labels:
    app: httpbin
  name: httpbin
  namespace: httpbin
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  rules:
  - host: httpbin.velannes.com
    http:
      paths:
      - backend:
          service:
            name: httpbin
            port:
              number: 8080
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - httpbin.velannes.com
    secretName: letsencrypt-staging
```

* Verify (failed because I must create the file `http://httpbin.velannes.com/.well-known/acme-challenge/1G-z_pI52bEaxnROxLTZN6rEKGh6e0gVx5nvCBBa_Yc` to have a `200` status code)
```shell
$ kubectl get challenges.acme.cert-manager.io -n httpbin letsencrypt-staging-1-3833201168-3469451843 -o jsonpath="{.status.reason}"
Waiting for HTTP-01 challenge propagation: failed to perform self check GET request 'http://httpbin.velannes.com/.well-known/acme-challenge/1G-z_pI52bEaxnROxLTZN6rEKGh6e0gVx5nvCBBa_Yc': Get "http://httpbin.velannes.com/.well-known/acme-challenge/1G-z_pI52bEaxnROxLTZN6rEKGh6e0gVx5nvCBBa_Yc": dial tcp: lookup httpbin.velannes.com on 10.43.0.10:53: no such hostroot@k8s-m1
```

### Solver dns01
* [Cert-manager dns01 documentation](https://cert-manager.io/docs/configuration/acme/dns01/)
