# metallb

# configuration
Since the version 0.13, you must configure the crd [custom.yaml](/argocd/metallb/custom.yaml):

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  autoAssign: True
  addresses:
    - 192.168.122.200-192.168.122.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
```

It is automatically installed by the install script `install.sh`:
```shell
kubectl apply -f "$(dirname $0)/custom.yaml"
```

# monitoring
You need to configure the grafana dashboard [14127](https://grafana.com/grafana/dashboards/14127).
