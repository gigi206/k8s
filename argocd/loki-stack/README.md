# loki-stack
## Articles
* https://blog.octo.com/the-long-way-to-loki

## Promtail
### Scraping
* https://grafana.com/docs/loki/latest/clients/promtail/scraping/#relabeling

Example builtin vars:
```
__address__=\"10.42.0.2\"
__meta_kubernetes_namespace=\"istio-cni\"
__meta_kubernetes_pod_annotation_ambient_istio_io_redirection=\"disabled\"
__meta_kubernetes_pod_annotation_cni_projectcalico_org_containerID=\"fce6e681dc2a57ef650438b55605e775aa336d30511487207bd5b2e86c12bd4d\"
__meta_kubernetes_pod_annotation_cni_projectcalico_org_podIP=\"10.42.0.2/32\"
__meta_kubernetes_pod_annotation_cni_projectcalico_org_podIPs=\"10.42.0.2/32\"
__meta_kubernetes_pod_annotation_prometheus_io_path=\"/metrics\"
__meta_kubernetes_pod_annotation_prometheus_io_port=\"15014\"
__meta_kubernetes_pod_annotation_prometheus_io_scrape=\"true\"
__meta_kubernetes_pod_annotation_sidecar_istio_io_inject=\"false\"
__meta_kubernetes_pod_annotationpresent_ambient_istio_io_redirection=\"true\"
__meta_kubernetes_pod_annotationpresent_cni_projectcalico_org_containerID=\"true\"
__meta_kubernetes_pod_annotationpresent_cni_projectcalico_org_podIP=\"true\"
__meta_kubernetes_pod_annotationpresent_cni_projectcalico_org_podIPs=\"true\"
__meta_kubernetes_pod_annotationpresent_prometheus_io_path=\"true\"
__meta_kubernetes_pod_annotationpresent_prometheus_io_port=\"true\"
__meta_kubernetes_pod_annotationpresent_prometheus_io_scrape=\"true\"
__meta_kubernetes_pod_annotationpresent_sidecar_istio_io_inject=\"true\"
__meta_kubernetes_pod_container_id=\"containerd://6d868af4b91f71964069b142b577f065bc0e9b5251c78f6c0486a7ad21747b01\"
__meta_kubernetes_pod_container_image=\"docker.io/istio/install-cni:1.18.2\"
__meta_kubernetes_pod_container_init=\"false\"
__meta_kubernetes_pod_container_name=\"install-cni\"
__meta_kubernetes_pod_controller_kind=\"DaemonSet\"
__meta_kubernetes_pod_controller_name=\"istio-cni-node\"
__meta_kubernetes_pod_host_ip=\"192.168.121.102\"
__meta_kubernetes_pod_ip=\"10.42.0.2\"
__meta_kubernetes_pod_label_controller_revision_hash=\"5857f46b57\"
__meta_kubernetes_pod_label_k8s_app=\"istio-cni-node\"
__meta_kubernetes_pod_label_pod_template_generation=\"1\"
__meta_kubernetes_pod_label_sidecar_istio_io_inject=\"false\"
__meta_kubernetes_pod_labelpresent_controller_revision_hash=\"true\"
__meta_kubernetes_pod_labelpresent_k8s_app=\"true\"
__meta_kubernetes_pod_labelpresent_pod_template_generation=\"true\"
__meta_kubernetes_pod_labelpresent_sidecar_istio_io_inject=\"true\"
__meta_kubernetes_pod_name=\"istio-cni-node-h2mc4\"
__meta_kubernetes_pod_node_name=\"k8s-m1\"
__meta_kubernetes_pod_phase=\"Running\"
__meta_kubernetes_pod_ready=\"true\"
__meta_kubernetes_pod_uid=\"b11ce234-325b-443f-a166-9d1a9d88c352\"
```

### Debug
```
ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images ls | egrep ^docker.io/grafana/promtail: --color | awk '{ print $1 }'
docker.io/grafana/promtail:2.8.3
```

If no image present, pull it (latest):
```
ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images pull docker.io/grafana/promtail:latest
```

Run:
```
ctr --address /run/k3s/containerd/containerd.sock -n k8s.io run --tty --rm --net-host --mount type=bind,src="/var/log/pods",dst=/var/log/pods,options=rbind docker.io/grafana/promtail:2.8.3 promtail sh
```

Or latest:
```
ctr --address /run/k3s/containerd/containerd.sock -n k8s.io run --tty --rm --net-host --mount type=bind,src="/var/log/pods",dst=/var/log/pods,options=rbind docker.io/grafana/promtail:latest promtail sh
```

Install `vim`:
```bash
$ apt update
$ apt install vim
$ vim /etc/promtail/config.yaml
```

`/etc/promtail/config.yaml`:
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
- job_name: kubernetes-pods
  pipeline_stages:
    - cri: {}
    - regex:
        expression: "^(?P<log>.*)$"
    - template:
        source: log
        template: '{ log={{ quote .Value }} }'
    - output:
        source: log
  kubernetes_sd_configs:
    - role: pod
```

```bash
$ tail -1 $(ls -1 /var/log/pods/*/*/* -tr | tail -1) | promtail --dry-run --inspect --stdin -config.file /etc/promtail/config.yml
Clients configured:
----------------------
url: http://loki:3100/loki/api/v1/push
batchwait: 1s
batchsize: 1048576
follow_redirects: false
enable_http2: false
backoff_config:
  min_period: 500ms
  max_period: 5m0s
  max_retries: 10
timeout: 10s
tenant_id: ""
drop_rate_limited_batches: false
stream_lag_labels: ""

[inspect: regex stage]:
{stages.Entry}.Extracted["content"]:
	+: 2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes
{stages.Entry}.Extracted["flags"]:
	+: F
{stages.Entry}.Extracted["stream"]:
	+: stderr
{stages.Entry}.Extracted["time"]:
	+: 2023-08-24T21:17:26.287905137Z
[inspect: labels stage]:
{stages.Entry}.Entry.Labels:
	-: {}
	+: {stream="stderr"}
[inspect: timestamp stage]:
{stages.Entry}.Entry.Entry.Timestamp:
	-: 2023-08-24 21:17:27.035046596 +0000 UTC
	+: 2023-08-24 21:17:26.287905137 +0000 UTC
[inspect: output stage]:
{stages.Entry}.Entry.Entry.Line:
	-: 2023-08-24T21:17:26.287905137Z stderr F 2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes
	+: 2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes
[inspect: output stage]: none
[inspect: regex stage]:
{stages.Entry}.Extracted["log"]:
	+: 2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes
[inspect: template stage]:
{stages.Entry}.Extracted["log"].(string):
	-: 2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes
	+: { log="2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes" }
[inspect: output stage]:
{stages.Entry}.Entry.Entry.Line:
	-: 2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes
	+: { log="2023/08/24 21:17:26 Voted for [:cloud_with_rain:], which now has a total of [117] votes" }
```

### Documentaion
* https://grafana.com/docs/loki/latest/clients/promtail
* [kubernetes_sd_config](https://grafana.com/docs/loki/latest/clients/promtail/configuration/#kubernetes_sd_config)
* [Trace to logs](https://grafana.com/docs/grafana/latest/datasources/tempo/#trace-to-logs)
* https://gitee.com/mirrors/Grafana-Loki/blob/791262dc258e74a5457dedc82879d383cce2e66e/docs/clients/promtail/configuration.md#pod

## LogQL
* https://grafana.com/docs/loki/latest/logql

Some examples:
* All logs from container `dokuwiki` on stdout from namespace `dokuwiki` that contains `GET`:
```
{namespace="dokuwiki", container="dokuwiki", stream="stdout"} |~ `GET`
```

* Filter systemd messages:
```
{job="systemd-journal"} | json | line_format "{{.MESSAGE}}" | _EXE="/usr/bin/sudo"
```

* Format logs by uri and status: All logs from container `dokuwiki` on stdout from namespace `dokuwiki` that contains `GET` and have the status code `200`
```
{namespace="dokuwiki", container="dokuwiki", stream="stdout"} |~ "GET" | regexp "\"\\S+\\s+(?P<uri>\\S+)\\s+\\S+\"\\s+.*(?P<status>\\d{3}).*\\s+" | line_format "uri={{.uri}} status={{.status}}" | status=`200`
```

* Dynamic labels:
```
{namespace="dokuwiki", container="dokuwiki", stream="stdout"} |~ "GET" | pattern `<ip> - - <_> "<method> <uri> <_>" <status> <size>`
```

* Graph your logs:
```
count_over_time({namespace="dokuwiki", container="dokuwiki", stream="stdout"} |~ "GET" | pattern `<ip> - - <_> "<method> <uri> <_>" <status> <size>` [1m])
sum by (instance) (count_over_time({namespace="dokuwiki", container="dokuwiki", stream="stdout"} |~ "GET" | pattern `<ip> - - <_> "<method> <uri> <_>" <status> <size>` [1m]))
```

## Security issue

Loki is not secured by default.

It is recommended to use a `NetworkPolicy` to block the traffic to Loki.

But the proposed one in the charts is not sufficient secured because it permits anyone to connect to the 3100/TCP port.

Prefer apply the [NetworkPolicy.yaml](NetworkPolicy.yaml) to block the traffic and only allow the traffic from all daemonset (from the same namespace) and from the grafana app in the `prometheus-stack` namespace.
