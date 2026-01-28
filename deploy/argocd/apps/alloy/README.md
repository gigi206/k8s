# Grafana Alloy - Log Collector

Grafana Alloy is deployed as a DaemonSet to collect logs from Kubernetes and send them to Loki.

## Configuration

Configuration is in `config/dev.yaml` (or `prod.yaml`):

```yaml
alloy:
  namespace: alloy
  version: "0.12.0"  # Helm chart version

  controller:
    type: daemonset   # DaemonSet for node-level collection

  loki:
    url: "http://loki.loki.svc.cluster.local:3100/loki/api/v1/push"

  # Log sources configuration
  logs:
    pods:
      enabled: true     # Kubernetes pod logs (default)
    events:
      enabled: true     # Kubernetes Events
    journal:
      enabled: true     # Node journald logs (systemd services)
    rke2:
      enabled: true     # RKE2 node logs (kubelet.log, containerd.log)
```

## Log Sources

### Pod Logs (`logs.pods.enabled: true`)

Collects logs from all running Kubernetes pods using the Kubernetes API.

**Labels added:**
- `namespace`: Pod namespace
- `pod`: Pod name
- `container`: Container name
- `node`: Node where pod runs
- `app`: Value of `app` label
- `app_name`: Value of `app.kubernetes.io/name` label
- `job`: Format `{namespace}/{container}`

**Features:**
- JSON log parsing (extracts `level` and `msg`)
- TraceID extraction for log-to-trace correlation:
 - W3C Traceparent: `Traceparent:[00-<traceid>-...]`
 - B3: `X-B3-Traceid:[<traceid>]`

**Grafana query:**
```logql
{namespace="emojivoto", container="web"}
```

### Kubernetes Events (`logs.events.enabled: true`)

Collects cluster-wide Kubernetes events (pod scheduling, errors, warnings, etc.).

**Labels added:**
- `source`: `kubernetes-events`
- Standard event labels from Kubernetes

**Grafana query:**
```logql
{source="kubernetes-events"}
{source="kubernetes-events"} |= "error"
{source="kubernetes-events"} | json | type="Warning"
```

**Event types collected:**
- Pod scheduling (Scheduled, FailedScheduling)
- Pod lifecycle (Pulled, Created, Started, Killing)
- Warnings (FailedMount, BackOff, Unhealthy)
- Node events (NodeNotReady, NodeReady)
- Volume events (ProvisioningSucceeded, FailedAttach)

### Journal Logs (`logs.journal.enabled: true`)

Collects logs from node systemd services via journald.

**Requires:**
- hostPath volume mount to `/var/log/journal`
- securityContext with `fsGroup: 999` and `supplementalGroups: [999, 4]` (systemd-journal + adm)

**Labels added:**
- `source`: `journal`
- `unit`: Systemd unit name (e.g., `kubelet.service`)
- `node`: Hostname
- `level`: Log priority
- `job`: `journal`

**Grafana query:**
```logql
{source="journal", unit="kubelet.service"}
{source="journal", level="err"}
{source="journal"} |= "error"
```

**Services typically captured:**
- `kubelet.service`: Kubernetes node agent
- `containerd.service`: Container runtime
- `rke2-server.service` / `rke2-agent.service`: RKE2 services
- Other system services

### RKE2 Node Logs (`logs.rke2.enabled: true`)

Collects RKE2-specific log files from nodes (file-based, not journald).

**Requires:** hostPath volume mounts to `/var/lib/rancher/rke2/agent/logs` and `/var/lib/rancher/rke2/agent/containerd`

**Files collected:**
- `/var/lib/rancher/rke2/agent/logs/kubelet.log` - Kubelet logs
- `/var/lib/rancher/rke2/agent/containerd/containerd.log` - Container runtime daemon logs

**Labels added:**
- `source`: `rke2`
- `type`: `kubelet` or `containerd`

**Grafana query:**
```logql
{source="rke2"}
{source="rke2", type="kubelet"}
{source="rke2", type="containerd"}
{source="rke2"} |= "error"
```

**Note:** This is complementary to pod logs - it collects the runtime daemon logs, not container stdout/stderr.

## Architecture

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                         Alloy DaemonSet (per node)                            │
├───────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐     │
│  │ loki.source   │ │ loki.source   │ │ loki.source   │ │ loki.source   │     │
│  │ .kubernetes   │ │ .kubernetes   │ │ .journal      │ │ .file         │     │
│  │ (pod logs)    │ │ _events       │ │ (journald)    │ │ (rke2 logs)   │     │
│  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘ └───────┬───────┘     │
│          │                 │                 │                 │             │
│          ▼                 ▼                 ▼                 ▼             │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐     │
│  │ loki.process  │ │ loki.process  │ │ loki.process  │ │ loki.process  │     │
│  │ "pods"        │ │ "events"      │ │ "journal"     │ │ "rke2"        │     │
│  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘ └───────┬───────┘     │
│          │                 │                 │                 │             │
│          └─────────────────┴─────────────────┴─────────────────┘             │
│                                      │                                       │
│                                      ▼                                       │
│                          ┌─────────────────────┐                             │
│                          │ loki.write          │                             │
│                          │ "default"           │                             │
│                          └──────────┬──────────┘                             │
│                                     │                                        │
└─────────────────────────────────────┼────────────────────────────────────────┘
                                      │
                                      ▼
                          ┌─────────────────────┐
                          │       Loki          │
                          │  (log aggregation)  │
                          └─────────────────────┘
```

## Enabling/Disabling Log Sources

To enable all log sources:

```yaml
# config/dev.yaml
alloy:
  logs:
    pods:
      enabled: true
    events:
      enabled: true
    journal:
      enabled: true   # systemd/journald logs
    rke2:
      enabled: true   # RKE2 kubelet.log + containerd.log
```

To collect only pod logs and events (minimal):

```yaml
alloy:
  logs:
    pods:
      enabled: true
    events:
      enabled: true
    journal:
      enabled: false
    rke2:
      enabled: false
```

## Log-to-Trace Correlation

Pod logs automatically extract traceID from Istio access logs for correlation with Tempo traces.

See the [Istio README](../istio/README.md#distributed-tracing) for details on:
- Enabling access logs per namespace via Telemetry API
- Clicking traceID in Grafana to view trace in Tempo

## Monitoring

When `features.monitoring.enabled: true`:
- ServiceMonitor is created for Prometheus scraping
- PrometheusRules are deployed from `kustomize/monitoring/`
- Alloy self-metrics are exposed

### Prometheus Alerts

7 alertes sont configurées pour Alloy :

| Alerte | Sévérité | Description |
|--------|----------|-------------|
| AlloyDaemonSetNotRunning | critical | DaemonSet incomplet (5m) |
| AlloyPodNotReady | critical | Pod non ready (5m) |
| AlloyLogDeliveryFailures | high | Échec envoi logs vers Loki (10m) |
| AlloyPodCrashLooping | high | Pod en restart loop (10m) |
| AlloyHighMemoryUsage | warning | Mémoire > 85% (10m) |
| AlloyHighCPUUsage | warning | CPU > 85% (10m) |
| AlloySlowLogProcessing | medium | Traitement p99 > 1s (15m) |

### Métriques clés

```promql
# Envoi vers Loki
rate(loki_write_sent_bytes_total{job="alloy"}[5m])
rate(loki_write_dropped_bytes_total{job="alloy"}[5m])

# Traitement
histogram_quantile(0.99, rate(loki_process_duration_seconds_bucket{job="alloy"}[5m]))
```

## Troubleshooting

### Logs non collectés

```bash
# Vérifier les pods Alloy
kubectl get pods -n alloy

# Logs Alloy
kubectl logs -n alloy -l app.kubernetes.io/name=alloy

# Vérifier la configuration
kubectl get configmap -n alloy alloy -o yaml
```

### Erreurs d'envoi vers Loki

```bash
# Vérifier la connectivité vers Loki
kubectl exec -n alloy -l app.kubernetes.io/name=alloy -- \
  curl -s http://loki.loki.svc.cluster.local:3100/ready
```

## References

- [Grafana Alloy Documentation](https://grafana.com/docs/alloy/latest/)
- [Loki Log Sources](https://grafana.com/docs/alloy/latest/reference/components/loki.source.kubernetes/)
