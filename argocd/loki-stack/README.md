# loki-stack

## Configuration
Add a `Loki` datasource in **Grafana** with **URL**: **http://loki-stack.loki-stack:3100**

## Articles
* https://blog.octo.com/the-long-way-to-loki/

# LogQL
https://grafana.com/docs/loki/latest/logql/

Some examples:
* All logs from container `dokuwiki` on stdout from namespace `dokuwiki` that contains `GET`:
```
{namespace="dokuwiki", container="dokuwiki", stream="stdout"} |~ `GET`
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
