# Linkerd
## Pod injection
### Show injected pods
```bash
kubectl -n emojivoto get po -o jsonpath='{.items[0].spec.containers[*].name}' | xargs | egrep -w linkerd-proxy > /dev/null && echo "Meshed" || echo "Not meshed"
Meshed
```
### Injection by namespace
```bash
kubectl annotate namespace <namespace> linkerd.io/inject=enabled
```

```bash
kubectl create ns test --dry-run=client -o yaml | linkerd inject - | kubectl apply -f -
```

### Manual injection
```bash
kubectl get deploy -n <namespace> -o yaml | linkerd inject - | kubectl apply -f -
```

