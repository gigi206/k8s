# kubeshark
## Lens extension
* https://github.com/kubeshark/lens

## Examples:
```
src.namespace == "emojivoto" and http and response.status != 200
```

```
http and node.name == "k8s-m1" and request.path == "/api/vote" and src.name == "web-svc" and src.namespace == "emojivoto" and dst.name == "web-svc" and dst.namespace == "emojivoto"
```