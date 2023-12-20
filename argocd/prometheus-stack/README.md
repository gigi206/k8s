# prometheus-stack
## Backup
Use [this tool](https://github.com/ysde/grafana-backup-tool/tree/master) to backup Dashboards, Datasources and others to add easily with `ConfigMaps`.

## Prometheus
### Sysdig tips
* Sysdig: [How to rightsize the Kubernetes resource limits](https://sysdig.com/blog/kubernetes-resource-limits/)

* Containers without CPU limits by namespace:
```js
sum by (namespace)(count by (namespace,pod,container)(kube_pod_container_info{container!=""}) unless sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource="cpu"}))
```

* Containers without memory limits by namespace:
```js
sum by (namespace)(count by (namespace,pod,container)(kube_pod_container_info{container!=""}) unless sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource="memory"}))
```

* Top 10 containers without CPU limits, using more CPU:
```js
topk(10,sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!=""}[5m])) unless sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource="cpu"}))
```

* Top 10 containers without memory limits, using more memory:
```js
topk(10,sum by (namespace,pod,container)(container_memory_usage_bytes{container!=""}) unless sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource="memory"}))
```

* Detecting containers with very tight CPU limits:
```js
(sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{container!=""}[5m])) / sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource="cpu"})) > 0.8
```

* Containers whose memory usage is close to its limits:
```js
(sum by (namespace,pod,container)(container_memory_usage_bytes{container!=""}) / sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource="memory"})) > 0.8
```

* Finding the right CPU limit, with the conservative strategy:
```js
max by (namespace,owner_name,container)((rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) * on(namespace,pod) group_left(owner_name) avg by (namespace,pod,owner_name)(kube_pod_owner{owner_kind=~"DaemonSet|StatefulSet|Deployment"}))
```

* Finding the right memory limit, with the conservative strategy:
```js
max by (namespace,owner_name,container)((container_memory_usage_bytes{container!="POD",container!=""}) * on(namespace,pod) group_left(owner_name) avg by (namespace,pod,owner_name)(kube_pod_owner{owner_kind=~"DaemonSet|StatefulSet|Deployment"}))
```

* Finding the right CPU limit, with the aggressive strategy:
```js
quantile by (namespace,owner_name,container)(0.99,(rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) * on(namespace,pod) group_left(owner_name) avg by (namespace,pod,owner_name)(kube_pod_owner{owner_kind=~"DaemonSet|StatefulSet|Deployment"}))
```

* Finding the right memory limit, with the aggressive strategy:
```js
quantile by (namespace,owner_name,container)(0.99,(container_memory_usage_bytes{container!="POD",container!=""}) * on(namespace,pod) group_left(owner_name) avg by (namespace,pod,owner_name)(kube_pod_owner{owner_kind=~"DaemonSet|StatefulSet|Deployment"}))
```

* % memory overcommitted of the cluster:
```js
100 * sum(kube_pod_container_resource_limits{container!="",resource="memory"} ) / sum(kube_node_status_capacity{resource="memory"})
```

* % CPU overcommitted of the cluster:
```js
100 * sum(kube_pod_container_resource_limits{container!="",resource="cpu"} ) / sum(kube_node_status_capacity{resource="cpu"})
```

* % memory overcommitted of the node:
```js
sum by (node)(kube_pod_container_resource_limits{container!="",resource="memory"} ) / sum by (node)(kube_node_status_capacity{resource="memory"})
```

* % CPU overcommitted of the node
```js
sum by (node)(kube_pod_container_resource_limits{container!="",resource="cpu"} ) / sum by (node)(kube_node_status_capacity{resource="cpu"})
```

## issues

### crd
**Important:** the `kubectl replace` is dangerous to use with CRDs since `kubectl` might delete and recreate it.

When the `Application` is synced the following event appears:
```
Sync operation to 39.5.0 failed: one or more objects failed to apply, reason: CustomResourceDefinition.apiextensions.k8s.io "prometheuses.monitoring.coreos.com" is invalid: metadata.annotations: Too long: must have at most 262144 bytes
```

A workaround could be in argocd ui to click on the `CustomResourceDefinition` ressource `prometheusrules.monitoring.coreos.com` and click on the **sync** button and enable the checkbox `Replace` and the click on the **Synchronize** button.
After that tha last sync result is OK.

Another workaround would have been to patch the `CustomResourceDefinition` ressource `prometheusrules.monitoring.coreos.com` with adding the anootations:
```
argocd.argoproj.io/sync-options: Replace=true
```

And another one (better) is to create 2 ArgoCD `Application` (as explained [here](https://blog.ediri.io/kube-prometheus-stack-and-argocd-23-how-to-remove-a-workaround)):
* one for the crd only, with `.spec.syncPolicy.syncOptions` sets to `Replace=true`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack-crds
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  destination:
    name: in-cluster
    namespace: monitoring
  project: default
  source:
    repoURL: https://github.com/prometheus-community/helm-charts.git
    path: charts/kube-prometheus-stack/crds/
    targetRevision: kube-prometheus-stack-39.5.0
    directory:
      recurse: true
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - Replace=true
    automated:
      prune: true
      selfHeal: true
```
* another one that contains prometheus-stack without the crd installation (with `.spec.source.helm.skipCrds: true`)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus-stack
  namespace: argo-cd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  destination:
    namespace: prometheus-stack
    name: in-cluster
  source:
    chart: kube-prometheus-stack
    repoURL: 'https://prometheus-community.github.io/helm-charts'
    targetRevision: '39.5.0'
    helm:
      skipCrds: true
      values: |-
        #Snip the values
    chart: kube-prometheus-stack
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

This is because ArgoCD install with `kubectl sapply -f` and this command generate the annotation `kubectl.kubernetes.io/last-applied-configuration` that exceeds the size limit:
* when 1st time, use `kubectl create -f` when creating instead of `kubect apply -f`
* when **not** 1st time, use `kubectl replace -f` when replacing instead of `kubect apply -f`
