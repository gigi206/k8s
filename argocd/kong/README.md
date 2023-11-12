# Kong
## Annotations
* https://docs.konghq.com/kubernetes-ingress-controller/latest/references/annotations/

### HTTPS redirection
* https://docs.konghq.com/kubernetes-ingress-controller/latest/guides/configuring-https-redirect/:
* https://docs.konghq.com/kubernetes-ingress-controller/latest/references/annotations/#ingresskubernetesioforce-ssl-redirect
* https://docs.konghq.com/kubernetes-ingress-controller/latest/references/annotations/#konghqcomhttps-redirect-status-code
* https://docs.konghq.com/kubernetes-ingress-controller/latest/references/annotations/#konghqcomprotocols
```yaml
metadata:
  annotations:
    konghq.com/protocols: https
    konghq.com/https-redirect-status-code: '308'
    # konghq.com/https-redirect-status-code: '301'
    # konghq.com/https-redirect-status-code: '302'
```

### Backend HTTPS (service only)
* https://docs.konghq.com/kubernetes-ingress-controller/latest/references/annotations/#konghqcomprotocol
```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    konghq.com/protocol: https
```

## Plugins
### OIDC
* [Kong with Keycloak](https://dev.to/robincher/securing-your-site-via-oidc-powered-by-kong-and-keycloak-2ccc)
