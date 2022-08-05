# loki-stack

# Security issue

Loki is not secured by default.

It is recommended to use a `NetworkPolicy` to block the traffic to Loki.

But the proposed one in the charts is not sufficient secured because it permits anyone to connect to the 3100/TCP port.

Prefer apply the [NetworkPolicy.yaml](NetworkPolicy.yaml) to block the traffic and only allow the traffic from all daemonset (from the same namespace) and from the grafana app in the `prometheus-stack` namespace.
