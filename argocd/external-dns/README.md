# CoreDNS

## Disable CoreDNS

info: not tested yet

CoreDNS is bootstrapped when rke2 server is starting.

To disable CoreDNS add the following line in /etc/rancher/rke2/config.yaml:
```
disable: rke2-coredns
````

## Override CoreDNS configuration

Documentation: https://docs.rke2.io/helm/

RKE2 bootstrap some HelmChart here: **/var/lib/rancher/rke2/server/manifests/**

The file /var/lib/rancher/rke2/server/manifests/rke2-coredns-config.yaml is used to boostrap coredns

To list all HelmChart:
```
$ kubectl get HelmChart -A
NAMESPACE     NAME                  AGE
kube-system   rke2-canal            49d
kube-system   rke2-coredns          49d
kube-system   rke2-ingress-nginx    49d
kube-system   rke2-metrics-server   49d
```

To override a HelmChart you need to create a [HelmChartConfig](https://docs.rke2.io/helm/#customizing-packaged-components-with-helmchartconfig)
```
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-coredns
  namespace: kube-system
spec:
  valuesContent: |-
    image: coredns/coredns
    imageTag: v1.7.1
```

The HelmChart definition is explained [here](https://docs.rke2.io/helm/#helmchart-field-definitions)
