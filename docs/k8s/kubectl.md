# kubectl

### get
### Show custom columns
```shell
kubectl get all,ns -o custom-columns=Kind:.kind,Name:.metadata.name,Finalizers:.metadata.finalizers
```

### Filter
```shell
kubectl get pods --field-selector status.phase=Running
kubectl get pods --field-selector status.phase=Running -n longhorn-system -o name | awk -F'/' '{print $2}' | xargs kubectl -n longhorn-system delete pod
```
