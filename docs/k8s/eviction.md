# Pod eviction

## List evicted pods
```shell
kubectl get pods --field-selector=status.phase=Failed -A
```

## Delete evicted pods
```shell
kubectl delete pods --field-selector=status.phase=Failed -A
```
