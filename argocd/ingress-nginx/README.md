# ingress-nginx

# Dependencies
* [prometheus-stack](/argocd/prometheus-stack/prometheus-stack.yaml) (required by the CRDs used by the **prometheus-stack**)

## Monitoring
Please read the [documentation](https://kubernetes.github.io/ingress-nginx/user-guide/monitoring/).

You must install the [grafana dashboard](https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/grafana/dashboards/nginx.json).

You can use a specific dashboard version https://github.com/kubernetes/ingress-nginx/blob/helm-chart-`<tag>`/deploy/grafana/dashboards/nginx.json, example https://github.com/kubernetes/ingress-nginx/blob/helm-chart-4.2.1/deploy/grafana/dashboards/nginx.json.
