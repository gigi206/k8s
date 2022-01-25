# Kubernetes

## Pod Disruption Budget (pdb)

Please read the official documentation:
- [disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [configuration](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)

[Youtube](https://www.youtube.com/watch?v=09Wkw9uhPak&list=PL34sAs7_26wNBRWM6BDhnonoA5FMERax0&index=82)

```
kubectl get pdb
```

```
kubectl create pdb pdbdemo --min-available 50% --selector "run=nginx"

```
