# cert-manager

# Dependencies
* [prometheus-stack](/argocd/prometheus-stack/prometheus-stack.yaml) (required by the CRDs used by the **prometheus-stack**)

## Monitoring
The installation script `install.sh` installs some additionals `PrometheusRule` with the [prometheus.yaml](/argocd/cert-manager/prometheus.yaml) file.

Load the grafana dashboard with the [grafana.json](/argocd/cert-manager/grafana.json) file.

**important:** some parts of the dashboard are not fonctional and need work.
