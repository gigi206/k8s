# CoreDNS
* [Annotations](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/annotations/annotations.md)
* [Tutorials](https://github.com/kubernetes-sigs/external-dns/tree/master/docs/tutorials)

## CRD
When `crd.create` is set to `true` and `crd` is in the sources, you can defined `DNSEndpoint`:
```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: test.gigix
  namespace: test
spec:
  endpoints:
  - dnsName: test.gigix
    recordTTL: 180
    recordType: A
    targets:
    - 192.168.122.55
```

**INFO:** You can even create wildcard DNS entries, for example by setting dnsName: `*.test.example.com`.

## etcd TLS
* [Example with TLS enabled](https://particule.io/en/blog/k8s-no-cloud/)