# ingress-haproxy

2 versions of haproxy exist:
* [haproxytech](https://github.com/haproxytech/kubernetes-ingress/blob/master/documentation/annotations.md) (official)
  * https://artifacthub.io/packages/helm/haproxytech/kubernetes-ingress
* [jcmoraisjr/haproxy-ingress](https://github.com/jcmoraisjr/haproxy-ingress)
  * https://artifacthub.io/packages/helm/haproxy-ingress/haproxy-ingress

This one installs the official [haproxytech](https://github.com/haproxytech/kubernetes-ingress/blob/master/documentation/annotations.md)

# Dependencies
* [prometheus-stack](/argocd/prometheus-stack/prometheus-stack.yaml) (required by the CRDs used by the **prometheus-stack**)