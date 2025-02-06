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

# external-dns
## CoreDNS
### generic secret
Required if you used internal etcd (not this one installed with the current chart):
```shell
kubectl -n external-dns-system create secret generic etcd-client-certs \
  --from-file=ca.crt=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --from-file=client.crt=/var/lib/rancher/rke2/server/tls/etcd/client.crt \
  --from-file=client.key=/var/lib/rancher/rke2/server/tls/etcd/client.key
```
### cert-manager
* On crée le `ClusterIssuer`:
```shell
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: etcd-issuer
spec:
  ca:
    secretName: etcd-ca-secret  # Secret contenant server-ca.crt et sa clé
```

* Secret `etcd-client-certs`:
```shell
kubectl -n cert-manager create secret tls etcd-ca-secret \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-ca.key
```

* Certificates:
```shell
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: etcd-client-certs
  namespace: external-dns-system
spec:
  secretName: etcd-client-certs  # Nom du Secret à créer
  issuerRef:
    name: etcd-issuer
    kind: ClusterIssuer
  commonName: external-dns-client
  usages:
    - client auth
  # dnsNames:
  #   - external-dns.example.com
```

## Debugging
```shell
kubectl run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools
```
