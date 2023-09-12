# Linkerd-viz

# Grafana dashboard
This process is automatically done by the script [generate-grafana-dashboards.sh](./generate-grafana-dashboards.sh). Run it to update all dashboards.

Install all these dashboards in Grafana:

* [Linkerd Top Line](https://grafana.com/grafana/dashboards/15474)
* [Linkerd Deployment](https://grafana.com/grafana/dashboards/15475)
* [Linkerd Pod](https://grafana.com/grafana/dashboards/15477)
* [Linkerd Namespace](https://grafana.com/grafana/dashboards/15478)
* [Linkerd Service](https://grafana.com/grafana/dashboards/15480)
* [Linkerd Route](https://grafana.com/grafana/dashboards/15481)
* [Linkerd Authority](https://grafana.com/grafana/dashboards/15482)
* [Linkerd CronJob](https://grafana.com/grafana/dashboards/15483)
* [Linkerd DaemonSet](https://grafana.com/grafana/dashboards/15484)
* [Linkerd Health](https://grafana.com/grafana/dashboards/15486)
* [Linkerd Job](https://grafana.com/grafana/dashboards/15487)
* [Linkerd Multicluster](https://grafana.com/grafana/dashboards/15488)
* [Linkerd ReplicaSet](https://grafana.com/grafana/dashboards/15491)
* [Linkerd ReplicationController](https://grafana.com/grafana/dashboards/15492)
* [Linkerd StatefulSet](https://grafana.com/grafana/dashboards/15493)
* [Kubernetes cluster monitoring (via Prometheus)](https://grafana.com/grafana/dashboards/15479)
* [Prometheus 2.0 Stats](https://grafana.com/grafana/dashboards/15489)
* [Prometheus Benchmark - 2.7.x](https://grafana.com/grafana/dashboards/15490)

You can retrieve all these dashboards [here](https://grafana.com/orgs/linkerd/dashboards) or with the following script:

```bash
for id in $(curl -s https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml | egrep gnetId | awk '{ print $NF }' | sort); do echo https://grafana.com/grafana/dashboards/${id}; done
https://grafana.com/grafana/dashboards/15474
https://grafana.com/grafana/dashboards/15475
https://grafana.com/grafana/dashboards/15477
https://grafana.com/grafana/dashboards/15478
https://grafana.com/grafana/dashboards/15479
https://grafana.com/grafana/dashboards/15480
https://grafana.com/grafana/dashboards/15481
https://grafana.com/grafana/dashboards/15482
https://grafana.com/grafana/dashboards/15483
https://grafana.com/grafana/dashboards/15484
https://grafana.com/grafana/dashboards/15486
https://grafana.com/grafana/dashboards/15487
https://grafana.com/grafana/dashboards/15488
https://grafana.com/grafana/dashboards/15489
https://grafana.com/grafana/dashboards/15490
https://grafana.com/grafana/dashboards/15491
https://grafana.com/grafana/dashboards/15492
https://grafana.com/grafana/dashboards/15493
```
