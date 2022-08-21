# kubectl

## Show custom columns
```shell
kubectl get all,ns -o custom-columns=Kind:.kind,Name:.metadata.name,Finalizers:.metadata.finalizers
```
